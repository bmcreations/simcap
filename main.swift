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
    print("video\ninput\nui\nroute\nbitrate\npasteboard\ndevices")
    exit(0)
}
// Before CoreSimulator is loaded: a physical device needs none of it.
if args.first == "-devices" {
    runDevices(Array(args.dropFirst()))
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
guard let udid = args.first else {
    FileHandle.standardError.write("usage: simcap <udid> [-bitrate bps] [-fps n] [-maxsize px] [-input]\n".data(using: .utf8)!)
    exit(2)
}

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write("simcap: \(msg)\n".data(using: .utf8)!)
    exit(1)
}
@Sendable func log(_ msg: String) {
    FileHandle.standardError.write("simcap: \(msg)\n".data(using: .utf8)!)
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

if inputMode {
    runInput(device: device, udid: udid) {
        guard let s = currentSurface() else { return (0, 0, 0) }
        return (s.surf.width, s.surf.height, s.turn)
    }
}

// MARK: - output

let out = FileHandle.standardOutput
signal(SIGPIPE, SIG_IGN)
let writeLock = NSLock()

func write(_ data: Data) {
    writeLock.lock()
    defer { writeLock.unlock() }
    do { try out.write(contentsOf: data) } catch { exit(0) } // the reader is gone
}

func be64(_ v: UInt64) -> Data { withUnsafeBytes(of: v.bigEndian) { Data($0) } }
func be32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.bigEndian) { Data($0) } }

let flagConfig: UInt64 = 1 << 63
let flagKey: UInt64 = 1 << 62

func packet(pts: UInt64, flags: UInt64, _ payload: Data) {
    write(be64(pts | flags) + be32(UInt32(payload.count)) + payload)
}

// MARK: - encoder

let startCode = Data([0, 0, 0, 1])
var session: VTCompressionSession?
var width = 0, height = 0          // the framebuffer's
var turn = 0                       // clockwise degrees to stand it upright
var outWidth = 0, outHeight = 0    // the encoded picture's
var scaler: VTPixelTransferSession?
var scaledPool: CVPixelBufferPool?
var rotator: VTPixelRotationSession?
var rotatedPool: CVPixelBufferPool?
var lastParams = Data()
var forceKey = true
let encodeQueue = DispatchQueue(label: "simcap.encode", qos: .userInteractive)
let t0 = DispatchTime.now().uptimeNanoseconds

func annexB(_ sbuf: CMSampleBuffer) {
    guard let block = CMSampleBufferGetDataBuffer(sbuf), let fmt = CMSampleBufferGetFormatDescription(sbuf) else { return }
    let attachments = CMSampleBufferGetSampleAttachmentsArray(sbuf, createIfNecessary: false) as? [[CFString: Any]]
    let key = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
    let pts = UInt64(max(0, CMSampleBufferGetPresentationTimeStamp(sbuf).seconds) * 1_000_000)

    var nalLen: Int32 = 4
    if key {
        var params = Data()
        var count = 0
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                           parameterSetSizeOut: nil, parameterSetCountOut: &count,
                                                           nalUnitHeaderLengthOut: &nalLen)
        for i in 0..<count {
            var ptr: UnsafePointer<UInt8>?
            var size = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: i, parameterSetPointerOut: &ptr,
                                                               parameterSetSizeOut: &size, parameterSetCountOut: nil,
                                                               nalUnitHeaderLengthOut: nil)
            if let ptr { params += startCode + Data(bytes: ptr, count: size) }
        }
        if params != lastParams {
            lastParams = params
            packet(pts: 0, flags: flagConfig, params)
        }
    }

    var total = 0
    var raw: UnsafeMutablePointer<CChar>?
    guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &total,
                                      dataPointerOut: &raw) == noErr, let raw else { return }
    var payload = Data(capacity: total)
    var off = 0
    let n = Int(nalLen)
    while off + n <= total {
        var len = 0
        for i in 0..<n { len = len << 8 | Int(UInt8(bitPattern: raw[off + i])) }
        off += n
        guard off + len <= total else { break }
        payload += startCode
        payload.append(UnsafeRawPointer(raw + off).assumingMemoryBound(to: UInt8.self), count: len)
        off += len
    }
    packet(pts: pts, flags: key ? flagKey : 0, payload)
}

func makeSession(_ w: Int, _ h: Int) {
    var s: VTCompressionSession?
    let spec: [CFString: Any] = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true]
    let st = VTCompressionSessionCreate(allocator: nil, width: Int32(w), height: Int32(h), codecType: kCMVideoCodecType_H264,
                                        encoderSpecification: spec as CFDictionary, imageBufferAttributes: nil,
                                        compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
                                        compressionSessionOut: &s)
    guard st == noErr, let s else { fail("VTCompressionSessionCreate: \(st)") }
    let props: [CFString: Any] = [
        kVTCompressionPropertyKey_RealTime: true,
        kVTCompressionPropertyKey_AllowFrameReordering: false,
        kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_High_AutoLevel,
        kVTCompressionPropertyKey_AverageBitRate: bitRate,
        kVTCompressionPropertyKey_ExpectedFrameRate: maxFPS,
        kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 1.0,
    ]
    for (k, v) in props { VTSessionSetProperty(s, key: k, value: v as CFTypeRef) }
    VTCompressionSessionPrepareToEncodeFrames(s)
    session = s
}

// scaledSize fits w x h inside maxSize on its longest edge, keeping the shape,
// with both sides a multiple of 8 as scrcpy's own encoder rounds them.
func scaledSize(_ w: Int, _ h: Int) -> (Int, Int) {
    let long = max(w, h)
    // The encoder crops an odd side to even, which left the SPS a pixel
    // short of the header on the Duo's 2853x2007 inner panel.
    guard maxSize > 0, long > maxSize else { return (w & ~1, h & ~1) }
    let f = Double(maxSize) / Double(long)
    func r8(_ v: Int) -> Int { max(8, Int((Double(v) * f / 8).rounded()) * 8) }
    return (r8(w), r8(h))
}

// makePool makes a pool of w x h NV12 buffers backed by IOSurfaces.
func makePool(_ w: Int, _ h: Int) -> CVPixelBufferPool {
    let attrs: [CFString: Any] = [
        kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        kCVPixelBufferWidthKey: w,
        kCVPixelBufferHeightKey: h,
        kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
    ]
    var pool: CVPixelBufferPool?
    guard CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool) == kCVReturnSuccess, let pool else {
        fail("CVPixelBufferPoolCreate \(w)x\(h)")
    }
    return pool
}

// makeScaler prepares the turn and the downscale for a framebuffer of w x h,
// or clears them when the picture is encoded at its own size and upright.
// The turn is a VTPixelRotationSession into an upright buffer, since the
// transfer session only scales; the scale then runs on the upright picture.
func makeScaler(_ w: Int, _ h: Int, _ t: Int) {
    if let s = scaler { VTPixelTransferSessionInvalidate(s) }
    if let r = rotator { VTPixelRotationSessionInvalidate(r) }
    scaler = nil
    scaledPool = nil
    rotator = nil
    rotatedPool = nil
    let (uw, uh) = turned(w, h, t)
    if t != 0 {
        var r: VTPixelRotationSession?
        guard VTPixelRotationSessionCreate(nil, &r) == noErr, let r else {
            fail("VTPixelRotationSessionCreate")
        }
        let rotation: CFString = switch t {
        case 90: kVTRotation_CW90
        case 180: kVTRotation_180
        default: kVTRotation_CCW90
        }
        VTSessionSetProperty(r, key: kVTPixelRotationPropertyKey_Rotation, value: rotation)
        rotator = r
        rotatedPool = makePool(uw, uh)
    }
    guard (outWidth, outHeight) != (uw, uh) else { return }
    var s: VTPixelTransferSession?
    guard VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &s) == noErr, let s else {
        fail("VTPixelTransferSessionCreate")
    }
    VTSessionSetProperty(s, key: kVTPixelTransferPropertyKey_ScalingMode, value: kVTScalingMode_Normal)
    scaler = s
    scaledPool = makePool(outWidth, outHeight)
}

// The stream header needs dimensions, so it goes out with the first surface.
func writeHeader(_ w: Int, _ h: Int) {
    var name = Data(deviceName.utf8.prefix(63))
    name += Data(count: 64 - name.count)
    write(name + be32(0x6832_3634) + be32(UInt32(w)) + be32(UInt32(h))) // "h264"
}

var frames = 0
var lastEncode: UInt64 = 0
// Three quarters of the interval, not the whole of it. The simulator composites
// at 60Hz with jitter, so spacing captures by a full 16.7ms made every callback
// that landed a little early wait for the next one: 60fps in, 50 out.
let minGap = UInt64(1_000_000_000 / max(1, maxFPS)) * 3 / 4

func encode(_ surf: IOSurface, _ t: Int) {
    let w = surf.width, h = surf.height
    let (uw, uh) = turned(w, h, t)
    if session == nil {
        width = w; height = h; turn = t
        (outWidth, outHeight) = scaledSize(uw, uh)
        writeHeader(outWidth, outHeight)
        makeScaler(w, h, t)
        makeSession(outWidth, outHeight)
        log("\(deviceName) \(w)x\(h) turned \(t) as \(outWidth)x\(outHeight) \(bitRate)bps \(maxFPS)fps")
    } else if w != width || h != height || t != turn {
        // Rotation, a resize, or a fold onto another panel. The wire has no
        // way to re-announce size mid-stream except through the SPS, which
        // the config packet carries.
        VTCompressionSessionInvalidate(session!)
        width = w; height = h; turn = t
        (outWidth, outHeight) = scaledSize(uw, uh)
        makeScaler(w, h, t)
        makeSession(outWidth, outHeight)
        forceKey = true
        log("now \(w)x\(h) turned \(t) as \(outWidth)x\(outHeight)")
    }
    var pb: Unmanaged<CVPixelBuffer>?
    guard CVPixelBufferCreateWithIOSurface(nil, surf, nil, &pb) == kCVReturnSuccess, var pixels = pb?.takeRetainedValue() else {
        return
    }
    if let rotator, let rotatedPool {
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, rotatedPool, &out) == kCVReturnSuccess, let out,
              VTPixelRotationSessionRotateImage(rotator, pixels, out) == noErr else { return }
        pixels = out
    }
    if let scaler, let scaledPool {
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, scaledPool, &out) == kCVReturnSuccess, let out,
              VTPixelTransferSessionTransferImage(scaler, from: pixels, to: out) == noErr else { return }
        pixels = out
    }
    let now = DispatchTime.now().uptimeNanoseconds
    let pts = CMTime(value: CMTimeValue((now - t0) / 1000), timescale: 1_000_000)
    let opts: [CFString: Any]? = forceKey ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] : nil
    forceKey = false
    lastEncode = now
    frames += 1
    VTCompressionSessionEncodeFrame(session!, imageBuffer: pixels, presentationTimeStamp: pts, duration: .invalid,
                                    frameProperties: opts as CFDictionary?, infoFlagsOut: nil) { st, _, sbuf in
        if st == noErr, let sbuf { annexB(sbuf) }
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
// one-second keyframe interval honest on a screen nobody is touching.
let idle = DispatchSource.makeTimerSource(queue: encodeQueue)
idle.schedule(deadline: .now(), repeating: .milliseconds(250))
idle.setEventHandler {
    if DispatchTime.now().uptimeNanoseconds - lastEncode >= 250_000_000 { schedule() }
}
idle.resume()

// setBitRate changes the running encoder's target. Runs on encodeQueue, which
// owns the session.
func setBitRate(_ bps: Int) {
    bitRate = bps
    guard let s = session else { return }
    let st = VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, value: bps as CFTypeRef)
    log("bitrate \(bps)bps\(st == noErr ? "" : " failed: \(st)")")
}

// stdin: EOF means stop; byte 17 asks for a keyframe; 0x80 and a u32 sets the
// bitrate. Parsed as a stream rather than scanned for 17, because the u32 can
// contain one.
Thread.detachNewThread {
    var b = [UInt8](repeating: 0, count: 64)
    var q: [UInt8] = []
    while true {
        let n = read(0, &b, b.count)
        if n <= 0 { exit(0) }
        q += b[0..<n]
        while let op = q.first {
            if op == 17 {
                q.removeFirst()
                encodeQueue.async { forceKey = true }
            } else if op == 0x80 {
                guard q.count >= 5 else { break }
                let bps = q[1...4].reduce(0) { $0 << 8 | Int($1) }
                q.removeFirst(5)
                encodeQueue.async { setBitRate(bps) }
            } else {
                q.removeFirst()
            }
        }
    }
}

dispatchMain()
