// The H.264 encoder and scrcpy's video wire format, shared by a simulator's
// framebuffer (main.swift) and a physical iPhone's screen capture (phone.swift).
// Whoever feeds it sets streamName, then calls startControl and encodePixels.

import CoreMedia
import CoreVideo
import Foundation
import IOSurface
import VideoToolbox

// MARK: - output

// The name in the stream header: the simulator's or the phone's.
var streamName = "iPhone"

let out = FileHandle.standardOutput
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
        kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: Double(keyframeSecs),
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
    var name = Data(streamName.utf8.prefix(63))
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
    var pb: Unmanaged<CVPixelBuffer>?
    guard CVPixelBufferCreateWithIOSurface(nil, surf, nil, &pb) == kCVReturnSuccess, let pixels = pb?.takeRetainedValue() else {
        return
    }
    encodePixels(pixels, t)
}

// encodePixels encodes one picture turned t degrees clockwise from upright.
// Runs on encodeQueue, which owns the session.
func encodePixels(_ captured: CVPixelBuffer, _ t: Int) {
    let w = CVPixelBufferGetWidth(captured), h = CVPixelBufferGetHeight(captured)
    let (uw, uh) = turned(w, h, t)
    if session == nil {
        width = w; height = h; turn = t
        (outWidth, outHeight) = scaledSize(uw, uh)
        writeHeader(outWidth, outHeight)
        makeScaler(w, h, t)
        makeSession(outWidth, outHeight)
        log("\(streamName) \(w)x\(h) turned \(t) as \(outWidth)x\(outHeight) \(bitRate)bps \(maxFPS)fps")
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
    var pixels = captured
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
    // t0 first: a global outside main.swift is set on first use, so reading
    // it after now would put it later than now and the subtraction would trap.
    let start = t0
    let now = DispatchTime.now().uptimeNanoseconds
    let pts = CMTime(value: CMTimeValue((now - start) / 1000), timescale: 1_000_000)
    let opts: [CFString: Any]? = forceKey ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] : nil
    forceKey = false
    lastEncode = now
    frames += 1
    VTCompressionSessionEncodeFrame(session!, imageBuffer: pixels, presentationTimeStamp: pts, duration: .invalid,
                                    frameProperties: opts as CFDictionary?, infoFlagsOut: nil) { st, _, sbuf in
        if st == noErr, let sbuf { annexB(sbuf) }
    }
}

// setBitRate changes the running encoder's target. Runs on encodeQueue, which
// owns the session.
func setBitRate(_ bps: Int) {
    bitRate = bps
    guard let s = session else { return }
    let st = VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, value: bps as CFTypeRef)
    log("bitrate \(bps)bps\(st == noErr ? "" : " failed: \(st)")")
}

// startControl reads stdin: EOF means stop; byte 17 asks for a keyframe; 0x80
// and a u32 sets the bitrate. Parsed as a stream rather than scanned for 17,
// because the u32 can contain one.
func startControl() {
    signal(SIGPIPE, SIG_IGN)
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
}
