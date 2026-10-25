// simcap streams one iOS simulator's screen as H.264, in scrcpy's video wire
// format, so the Go side reads it with the same parser it uses for a device:
// a 64-byte device name, 12 bytes of codec meta, then a 12-byte header per
// packet with the config and keyframe flags in bits 63 and 62.
//
//   simcap <udid> [-bitrate bps] [-fps n]
//   simcap <udid> -input       inject input instead; see input.swift
//   simcap <udid> -pasteboard  print the pasteboard on each change; see pasteboard.swift
//   simcap -caps               print what this build can do, one per line
//   simcap -devices            list physical iPhones and their HID capabilities; see devices.swift
//   simcap <udid> -phone [name] stream a physical iPhone on a cable instead; see phone.swift
//   simcap <identifier> -phone-input  a physical iPhone's input; see phoneinput.swift
//   simcap <identifier> -phone-wifi [name]  stream a physical iPhone over Wi-Fi; see wifi.swift
//
// The framebuffer is reached through CoreSimulator and SimulatorKit, which are
// private and move with Xcode, so this is built on its own rather than by
// `make build`.
//
// Two things it must do that a change-driven capture does not: send a frame at
// startup, because a static screen composites nothing and the viewer would
// wait forever (trap 22's blank canvas), and keep re-encoding on an idle floor
// so a keyframe is always within reach. It exits when stdin closes, which is
// how the parent says it is done. A byte of 17 on stdin, scrcpy's
// TYPE_RESET_VIDEO, forces the next frame to be a keyframe. A byte of 0x80
// followed by a big-endian u32 sets the average bitrate on the running
// encoder, which scrcpy has no way to do.

import CoreMedia
import CoreVideo
import Foundation
import IOSurface
import ObjectiveC
import VideoToolbox

// MARK: - arguments

var args = Array(CommandLine.arguments.dropFirst())
func flag(_ name: String, _ def: Int) -> Int {
    guard let i = args.firstIndex(of: name), i + 1 < args.count, let v = Int(args[i + 1]) else { return def }
    args.removeSubrange(i...(i + 1))
    return v
}
// -caps lets the server tell a build with input from an older one, which
// would read -input as nothing and start streaming video into the reply pipe.
if args == ["-caps"] {
    print("video\ninput\nui\nroute\nbitrate\npasteboard\ndevices\nphone\nphoneinput\nphonewifi")
    exit(0)
}
// Before CoreSimulator is loaded: a physical device needs none of it.
if args.first == "-devices" {
    runDevices(Array(args.dropFirst()))
}
if args.count == 2, args[1] == "-phone-input" {
    runPhoneInput(identifier: args[0])
}
if args.count == 2, args[1] == "-pasteboard" {
    runPasteboardWatch(udid: args[0])
}
let inputMode = args.contains("-input")
args.removeAll { $0 == "-input" }
// A var because stdin can change it; a session rebuilt for a new shape keeps
// the rate last set rather than going back to the flag's.
var bitRate = flag("-bitrate", 8_000_000)
let maxFPS = flag("-fps", 60)
// Longest edge of the encoded picture, 0 for the framebuffer's own size. The
// framebuffer is 1206x2622 on an iPhone 17, six times the pixels of a phone
// capped at 1080, and at that size a keyframe took 176ms to write to a viewer.
let maxSize = flag("-maxsize", 0)
// Seconds between keyframes. A viewer that sheds a frame asks for one, so this
// only bounds the wait when nobody asks.
let keyframeSecs = max(1, flag("-keyint", 1))
guard let udid = args.first else {
    FileHandle.standardError.write("usage: simcap <udid> [-bitrate bps] [-fps n] [-maxsize px] [-keyint s] [-input]\n".data(using: .utf8)!)
    exit(2)
}

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write("simcap: \(msg)\n".data(using: .utf8)!)
    exit(1)
}
@Sendable func log(_ msg: String) {
    FileHandle.standardError.write("simcap: \(msg)\n".data(using: .utf8)!)
}

// Before CoreSimulator is loaded, and after the flags the encoder reads.
if args.count >= 2, args[1] == "-phone" {
    runPhone(udid: args[0], name: args.count > 2 ? args[2] : "")
}
if args.count >= 2, args[1] == "-phone-wifi" {
    runPhoneWifi(identifier: args[0], name: args.count > 2 ? args[2] : "")
}

// MARK: - private frameworks

func developerDir() -> String {
    if let d = ProcessInfo.processInfo.environment["DEVELOPER_DIR"] { return d }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
    p.arguments = ["-p"]
    let out = Pipe()
    p.standardOutput = out
    try? p.run()
    p.waitUntilExit()
    let s = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return s.isEmpty ? "/Applications/Xcode.app/Contents/Developer" : s
}

let devDir = developerDir()
let coreSim = "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator"
if dlopen(coreSim, RTLD_NOW | RTLD_GLOBAL) == nil { fail("dlopen \(coreSim): \(String(cString: dlerror()))") }
// SimulatorKit has lived under Developer/Library/PrivateFrameworks and, in
// Xcode 27, under Contents/SharedFrameworks. Neither is promised.
let simKits = [
    devDir + "/../SharedFrameworks/SimulatorKit.framework/SimulatorKit",
    devDir + "/Library/PrivateFrameworks/SimulatorKit.framework/SimulatorKit",
]
if !simKits.contains(where: { dlopen($0, RTLD_NOW | RTLD_GLOBAL) != nil }) {
    fail("SimulatorKit not found under \(devDir)")
}

// Calls a selector taking (arg, NSError**) or (NSError**) and returning an object.
func callWithError(_ target: AnyObject, _ sel: Selector, _ arg: AnyObject?) -> AnyObject? {
    let isClass = object_isClass(target)
    let cls: AnyClass = isClass ? object_getClass(target)! : type(of: target)
    guard let m = isClass ? class_getClassMethod(target as? AnyClass, sel) : class_getInstanceMethod(cls, sel) else {
        return nil
    }
    let imp = method_getImplementation(m)
    var err: NSError?
    if let arg {
        typealias Fn = @convention(c) (AnyObject, Selector, AnyObject, AutoreleasingUnsafeMutablePointer<NSError?>) -> Unmanaged<AnyObject>?
        return withUnsafeMutablePointer(to: &err) { p in
            unsafeBitCast(imp, to: Fn.self)(target, sel, arg, AutoreleasingUnsafeMutablePointer(p))?.takeUnretainedValue()
        }
    }
    typealias Fn = @convention(c) (AnyObject, Selector, AutoreleasingUnsafeMutablePointer<NSError?>) -> Unmanaged<AnyObject>?
    return withUnsafeMutablePointer(to: &err) { p in
        unsafeBitCast(imp, to: Fn.self)(target, sel, AutoreleasingUnsafeMutablePointer(p))?.takeUnretainedValue()
    }
}

guard let ctxClass = NSClassFromString("SimServiceContext"),
      let ctx = callWithError(ctxClass, NSSelectorFromString("sharedServiceContextForDeveloperDir:error:"), devDir as NSString),
      let set = callWithError(ctx, NSSelectorFromString("defaultDeviceSetWithError:"), nil) as? NSObject,
      let devices = set.value(forKey: "devices") as? [NSObject]
else { fail("no CoreSimulator device set") }

guard let device = devices.first(where: { ($0.value(forKey: "UDID") as? NSUUID)?.uuidString == udid.uppercased() })
else { fail("no simulator \(udid)") }
let deviceName = (device.value(forKey: "name") as? String) ?? "Simulator"
guard (device.value(forKey: "state") as? NSNumber)?.intValue == 3 else { fail("\(deviceName) is not booted") }

guard let io = device.perform(NSSelectorFromString("io"))?.takeUnretainedValue() as? NSObject else {
    fail("device has no io client")
}

func displayDescriptors() -> [NSObject] {
    guard let ports = io.value(forKey: "deviceIOPorts") as? [NSObject] else { return [] }
    return ports.compactMap { port in
        guard let id = port.perform(NSSelectorFromString("portIdentifier"))?.takeUnretainedValue(),
              "\(id)" == "com.apple.framebuffer.display",
              let desc = port.perform(NSSelectorFromString("descriptor"))?.takeUnretainedValue() as? NSObject,
              desc.responds(to: NSSelectorFromString("framebufferSurface"))
        else { return nil }
        return desc
    }
}

var descriptors = displayDescriptors()
if descriptors.isEmpty {
    io.perform(NSSelectorFromString("updateIOPorts"))
    descriptors = displayDescriptors()
}
guard !descriptors.isEmpty else { fail("no framebuffer display port") }

// The main display is the lit one where CoreDevice says which that is (see
// displays.swift), and otherwise the largest surface. A phone has one; the
// others are overlays or external displays. turn is how far the surface is
// turned clockwise to stand upright, which only the lit panel can know.
func currentSurface() -> (surf: IOSurface, turn: Int)? {
    var best: IOSurface?
    let lit = litDisplay()
    for d in descriptors {
        guard let s = d.perform(NSSelectorFromString("framebufferSurface"))?.takeUnretainedValue() else { continue }
        let surf = unsafeBitCast(s, to: IOSurface.self)
        if let lit, surf.width == lit.width, surf.height == lit.height { return (surf, lit.turn) }
        if best == nil || surf.width * surf.height > best!.width * best!.height { best = surf }
    }
    return best.map { ($0, 0) }
}
loadPanelSpecs(device: device)
watchLitDisplay(udid: udid)

streamName = deviceName

if inputMode {
    runInput(device: device, udid: udid) {
        guard let s = currentSurface() else { return (0, 0, 0) }
        return (s.surf.width, s.surf.height, s.turn)
    }
}

// Coalesces composite callbacks: at most one capture is queued, and captures
// are spaced by the frame interval.
var pending = false
func schedule() {
    encodeQueue.async {
        if pending { return }
        pending = true
        let now = DispatchTime.now().uptimeNanoseconds
        let wait = lastEncode + minGap > now ? lastEncode + minGap - now : 0
        encodeQueue.asyncAfter(deadline: .now() + .nanoseconds(Int(wait))) {
            pending = false
            autoreleasepool { if let s = currentSurface() { encode(s.surf, s.turn) } }
        }
    }
}

// MARK: - wiring

let register = NSSelectorFromString("registerScreenCallbacksWithUUID:callbackQueue:frameCallback:surfacesChangedCallback:propertiesChangedCallback:")
let callbackQueue = DispatchQueue(label: "simcap.callbacks")
for d in descriptors where d.responds(to: register) {
    let changed: @convention(block) () -> Void = { schedule() }
    let props: @convention(block) () -> Void = {}
    typealias Fn = @convention(c) (AnyObject, Selector, AnyObject, AnyObject, AnyObject, AnyObject, AnyObject) -> Void
    let imp = class_getMethodImplementation(type(of: d), register)!
    unsafeBitCast(imp, to: Fn.self)(d, register, NSUUID(), callbackQueue, changed as AnyObject, changed as AnyObject, props as AnyObject)
}

// The idle floor: a static screen composites nothing, so re-encode what is
// there every 250ms. That is what gets a frame out at startup and keeps the
// keyframe interval honest on a screen nobody is touching.
let idle = DispatchSource.makeTimerSource(queue: encodeQueue)
idle.schedule(deadline: .now(), repeating: .milliseconds(250))
idle.setEventHandler {
    if DispatchTime.now().uptimeNanoseconds - lastEncode >= 250_000_000 { schedule() }
}
idle.resume()

onKeyRequest = schedule
startControl()

dispatchMain()
