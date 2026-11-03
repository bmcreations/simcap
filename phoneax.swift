// `simcap <coredevice id> -phone-ax-probe <service>` opens a socket to a
// service on a physical phone through CoreDevice's createServiceSocket and
// hands it to AccessibilityAudit's AXAuditRemoteDevice, the path Xcode's
// DeviceKit takes for the phone's accessibility tree. A probe, not a feature:
// on macOS 26B118 with iOS 27.2, remoted refuses
// com.apple.accessibility.axAuditDaemon.remoteAXService to CoreDeviceService
// ("Client lacks privilege"), so the socket never opens. The same call opens
// com.apple.instruments.dtservicehub. See loupe docs/ios.md.
import AppKit
import CoreDevice
import Foundation
import ObjectiveC

private let auditFramework = "/Applications/Xcode-27.1.0-Beta.app/Contents/SharedFrameworks/AccessibilityAudit.framework/AccessibilityAudit"

func runPhoneAXProbe(identifier: String, service: String) -> Never {
    guard let want = UUID(uuidString: identifier) else { fail("bad id") }
    let t0 = Date()
    func ms() -> Int { Int(Date().timeIntervalSince(t0) * 1000) }
    var fh: FileHandle?
    var size = CGSize.zero
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        defer { done.signal() }
        guard let dev = await coreDevice(want) else { log("no device"); return }
        do {
            _ = try await dev.acquireDeviceUsageAssertion(withReason: "simcap ax probe", options: UsageAssertionOptions(requiredPreparedness: .powerAssertionTaken))
            log("assertion at \(ms())ms")
            if let info = try? await dev.displayInfo,
               let d = info.displays.first(where: { !$0.external && $0.nativeSize.width > 0 }) { size = d.nativeSize }
            let impl = try await implementation(dev, CapabilityStaticMember<CreateServiceSocketCapability>.createServiceSocket)
            guard let s = impl as? any CreateServiceSocketProtocol else { log("not CreateServiceSocketProtocol: \(type(of: impl))"); return }
            fh = try await s.fileHandle(toServiceNamed: service)
        } catch { log("socket: \(error)") }
    }
    done.wait()
    guard let fh else { fail("no socket after \(ms())ms") }
    log("socket fd \(fh.fileDescriptor) native \(size) at \(ms())ms")
    guard dlopen(auditFramework, RTLD_NOW | RTLD_GLOBAL) != nil else { fail(String(cString: dlerror())) }
    guard let cls = NSClassFromString("AXAuditRemoteDevice") as? NSObject.Type else { fail("no AXAuditRemoteDevice") }
    let pts = CGSize(width: size.width / 3, height: size.height / 3)
    typealias InitFn = @convention(c) (AnyObject, Selector, Int32, NSString, CGSize) -> Unmanaged<AnyObject>?
    let sel = NSSelectorFromString("initWithFileDescriptor:identifier:deviceSize:")
    let obj = cls.perform(NSSelectorFromString("alloc"))!.takeUnretainedValue()
    let imp = class_getMethodImplementation(cls, sel)!
    guard let rd = unsafeBitCast(imp, to: InitFn.self)(obj, sel, fh.fileDescriptor, identifier as NSString, pts)?.takeRetainedValue() as? NSObject
    else { fail("init failed") }
    log("remote device \(rd) at \(ms())ms conn=\(String(describing: rd.value(forKey: "connection")))")
    rd.perform(NSSelectorFromString("startAccessibility"))
    log("started at \(ms())ms api=\(String(describing: rd.value(forKey: "deviceAPIVersion"))) cache=\(String(describing: rd.value(forKey: "hostCacheManager"))) overlay=\(String(describing: rd.value(forKey: "accessibilityOverlayView")))")
    for i in 0..<20 {
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        if let ov = rd.value(forKey: "accessibilityOverlayView") as? NSObject {
            let kids = ov.value(forKey: "accessibilityChildren") as? [NSObject] ?? []
            log("[\(i)] \(ms())ms overlay kids=\(kids.count) api=\(String(describing: rd.value(forKey: "deviceAPIVersion")))")
            if !kids.isEmpty {
                func walk(_ e: NSObject, _ d: Int) {
                    let r = e.value(forKey: "accessibilityRole") ?? ""
                    let l = e.value(forKey: "accessibilityLabel") ?? ""
                    let f = (e.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue ?? .zero
                    print(String(repeating: " ", count: d) + "\(r) '\(l)' \(f)")
                    if d < 12, let k = e.value(forKey: "accessibilityChildren") as? [NSObject] { k.forEach { walk($0, d + 1) } }
                }
                kids.forEach { walk($0, 0) }
                log("walked at \(ms())ms")
                exit(0)
            }
        }
    }
    fail("no tree after \(ms())ms")
}
