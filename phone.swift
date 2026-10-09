// simcap <udid> -phone streams a physical iPhone on a cable, through the
// screen-capture device QuickTime records from. That device exists only once
// a process sets CoreMediaIO's kCMIOHardwarePropertyAllowScreenCaptureDevices,
// and then appears a moment later as a muxed AVCaptureDevice. Over Wi-Fi there
// is no such device; see CLAUDE.md, "Physical iOS devices".
//
// Frames go through the same encoder as a simulator's (encoder.swift), so the
// Go side reads the same wire format either way.

import AVFoundation
import CoreMediaIO
import Darwin
import Foundation

// TCC charges a camera request to the process responsible for this one, which
// is whoever launched it: Claude Code, a terminal, or loupe under launchd.
// Claude Code lacks the camera entitlement and is refused with no prompt, and
// loupe is re-signed by every `make build`, which would forget the grant on
// every deploy. So simcap re-spawns itself responsible for itself, and the
// one grant is simcap's (its Info.plist, linked into __TEXT, carries the
// usage string). responsibility_spawnattrs_setdisclaim is private; it is
// what Terminal-launched tools use to the same end.
func disclaimResponsibility() {
    let marker = "SIMCAP_DISCLAIMED"
    if ProcessInfo.processInfo.environment[marker] != nil { return }
    typealias Disclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32
    guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim") else {
        log("phone: cannot disclaim responsibility; the camera grant falls to whoever launched simcap")
        return
    }
    var attr: posix_spawnattr_t?
    posix_spawnattr_init(&attr)
    _ = unsafeBitCast(sym, to: Disclaim.self)(&attr, 1)
    setenv(marker, "1", 1)
    let argv = CommandLine.arguments.map { strdup($0) } + [nil]
    var pid: pid_t = 0
    let st = posix_spawn(&pid, CommandLine.arguments[0], nil, &attr, argv, environ)
    if st != 0 { fail("phone: re-spawning disclaimed: \(String(cString: strerror(st)))") }
    // stdin, stdout and stderr are inherited; the child owns them now. A
    // signal to this process is passed on, so the server's kill still lands.
    for s in [SIGTERM, SIGINT, SIGHUP] {
        signal(s, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: s, queue: .global())
        src.setEventHandler { kill(pid, s) }
        src.resume()
        disclaimSignals.append(src)
    }
    var status: Int32 = 0
    while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
    exit((status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f))
}
var disclaimSignals: [DispatchSourceSignal] = []

func allowScreenCaptureDevices() {
    var addr = CMIOObjectPropertyAddress(
        mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
        mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
        mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    var allow: UInt32 = 1
    let st = CMIOObjectSetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &addr, 0, nil,
                                       UInt32(MemoryLayout<UInt32>.size), &allow)
    if st != 0 { log("phone: allowing screen capture devices: \(st)") }
}

// The capture device's uniqueID is neither the UDID nor CoreDevice's
// identifier: an iPhone 16 Pro on iOS 26.6 read C8397C0D-..., a UUID of its
// own. So the device is matched by the name devicectl reports, which the
// capture device carries as localizedName, and refused when two share it.
func bareID(_ s: String) -> String { s.replacingOccurrences(of: "-", with: "").uppercased() }

func findScreenCaptureDevice(_ udid: String, named name: String, within seconds: Double) -> AVCaptureDevice? {
    let deadline = Date().addingTimeInterval(seconds)
    var seen: [String] = []
    repeat {
        let devs = AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .muxed,
                                                    position: .unspecified).devices
        if let d = devs.first(where: { bareID($0.uniqueID) == bareID(udid) }) { return d }
        let named = devs.filter { !name.isEmpty && $0.localizedName == name }
        if named.count > 1 { fail("phone: \(named.count) capture devices are named \(name)") }
        if let d = named.first { return d }
        seen = devs.map { "\($0.localizedName) (\($0.uniqueID))" }
        // The run loop, not a sleep: CoreMediaIO announces the device on it.
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
    } while Date() < deadline
    log("phone: muxed devices seen: \(seen.isEmpty ? "none" : seen.joined(separator: ", "))")
    return nil
}

final class PhoneFrames: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    // The newest picture, re-encoded on the idle floor: a screen nobody is
    // touching delivers nothing, and the viewer still needs a keyframe a second.
    var last: CVPixelBuffer?

    func captureOutput(_ output: AVCaptureOutput, didOutput sbuf: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sbuf) else { return }
        last = pb
        if DispatchTime.now().uptimeNanoseconds - lastEncode >= minGap { encodePixels(pb, 0) }
    }
}

let phoneFrames = PhoneFrames()
let phoneSession = AVCaptureSession()

func runPhone(udid: String, name: String) -> Never {
    disclaimResponsibility()
    allowScreenCaptureDevices()
    // A screen-capture device is a camera to TCC. Not determined, the session
    // runs and delivers nothing, so ask, which prompts on the Mac once for
    // whichever app is responsible for this process.
    if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
        let asked = DispatchSemaphore(value: 0)
        AVCaptureDevice.requestAccess(for: .video) { _ in asked.signal() }
        while asked.wait(timeout: .now()) == .timedOut {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
    }
    let auth = AVCaptureDevice.authorizationStatus(for: .video)
    if auth != .authorized { log("phone: camera authorization is \(auth.rawValue), so no frames will arrive") }
    NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: nil, queue: nil) { n in
        log("phone: capture error: \(String(describing: n.userInfo?[AVCaptureSessionErrorKey]))")
    }
    guard let dev = findScreenCaptureDevice(udid, named: name, within: 10) else {
        fail("no screen capture device for \(udid): is it on a cable, unlocked and trusting this Mac?")
    }
    streamName = dev.localizedName
    let input: AVCaptureDeviceInput
    do { input = try AVCaptureDeviceInput(device: dev) } catch { fail("phone: opening \(dev.localizedName): \(error)") }
    let output = AVCaptureVideoDataOutput()
    output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
    output.alwaysDiscardsLateVideoFrames = true
    output.setSampleBufferDelegate(phoneFrames, queue: encodeQueue)
    phoneSession.beginConfiguration()
    guard phoneSession.canAddInput(input) else { fail("phone: cannot add \(dev.localizedName) as input") }
    phoneSession.addInput(input)
    guard phoneSession.canAddOutput(output) else { fail("phone: cannot add a video output") }
    phoneSession.addOutput(output)
    phoneSession.commitConfiguration()
    phoneSession.startRunning()
    log("phone: capturing \(dev.localizedName)")

    let idle = DispatchSource.makeTimerSource(queue: encodeQueue)
    idle.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250))
    idle.setEventHandler {
        if let pb = phoneFrames.last, DispatchTime.now().uptimeNanoseconds - lastEncode >= 250_000_000 {
            encodePixels(pb, 0)
        }
    }
    idle.resume()
    startControl()
    dispatchMain()
}
