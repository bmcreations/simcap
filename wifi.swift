// simcap <identifier> -phone-wifi [name] streams a physical iPhone over Wi-Fi. The
// identifier is CoreDevice's UUID, as for -phone-input.
//
// CoreDeviceMediaStreamSupport negotiates a mirrored stream with the phone,
// the one Device Hub shows, and the phone starts sending RTP over UDP inside
// the CoreDevice tunnel. The Mac's own receiver is avconferenced, which
// refuses any process without the restricted
// com.apple.videoconference.allow-conferencing entitlement and so never opens
// the port. simcap opens it instead: it reads the receiver address and the
// Mac's negotiated SSRC from CoreDevice's log lines for this process, binds
// UDP there, and answers with RTCP receiver reports under that SSRC. With any
// other SSRC the phone gives up after 15s with "AVC video stream RTCP
// timeout".
//
// The payload is HEVC (RFC 7798), unencrypted, RTCP muxed on the same port.
// It is decoded here and re-encoded as H.264 by encoder.swift, because Safari
// cannot decode HEVC (trap 24), and the server then reads the same wire
// format as a simulator's. Measured on bmc-iphone (iOS 27.2): a Home press
// visible in the received video 530-557ms after it was sent, against
// 641-678ms through Device Hub's window. A phone before iOS 27 refuses the
// stream: "Remote control requires iOS 27.0".

import CoreDevice
import CoreDeviceMediaStreamSupport
import CoreMedia
import Darwin
import ObjectiveC
import Foundation
import QuartzCore
import VideoToolbox

private func be16(_ b: UnsafeRawBufferPointer, _ i: Int) -> Int { Int(b[i]) << 8 | Int(b[i + 1]) }
private func be32(_ b: UnsafeRawBufferPointer, _ i: Int) -> UInt32 {
    UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])
}
private func bytes32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)] }

// MARK: - the negotiation, read from this process's own log

// watchNegotiation tails `log stream` for this process. CoreDevice logs the
// receiver it told the phone to send to ("ReceiverIP: <ip>, port: <p>") and
// then the session config it gave avconferenced, which carries the Mac's
// SSRC. Nothing in the framework's API returns either. It returns once the
// log stream is running, so nothing logged after is missed.
private func watchNegotiation(receiver: @escaping (String, UInt16) -> Void, ssrc: @escaping (UInt32) -> Void) -> Process {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/log")
    p.arguments = ["stream", "--style", "compact", "--predicate",
                   "processID == \(getpid()) AND (eventMessage CONTAINS \"ReceiverIP\" OR eventMessage CONTAINS \"vcMediaStreamLocalSSRC\")"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { fail("wifi: starting log stream: \(error)") }
    let started = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
        var acc = "", sawReceiver = false, first = true
        while true {
            let d = pipe.fileHandleForReading.availableData
            if first { first = false; started.signal() }
            if d.isEmpty { return }
            acc += String(decoding: d, as: UTF8.self)
            if !sawReceiver, let r = acc.range(of: "ReceiverIP: ") {
                let rest = acc[r.upperBound...]
                if let comma = rest.range(of: ", port: "), let nl = rest[comma.upperBound...].firstIndex(where: { !$0.isNumber }),
                   let port = UInt16(rest[comma.upperBound..<nl]) {
                    sawReceiver = true
                    receiver(String(rest[..<comma.lowerBound]), port)
                }
            }
            if let r = acc.range(of: "vcMediaStreamLocalSSRC = ") {
                let digits = acc[r.upperBound...].prefix(while: { $0.isNumber })
                if let v = UInt32(digits), digits.endIndex < acc.endIndex {
                    ssrc(v)
                    p.terminate()
                    return
                }
            }
        }
    }
    // log stream prints its "Filtering the log data" line once it is
    // attached.
    if started.wait(timeout: .now() + 5) == .timedOut { log("wifi: log stream said nothing in 5s") }
    return p
}

// MARK: - latency

// LatencyLog is measurement only, on with SIMCAP_LATENCY=1. It logs t0 as wall
// time once, so a client on this Mac can turn any PTS into a wall time, and
// every 5s how long the H.264 track spends between an access unit's arrival
// and its re-encode starting: the decode the passthrough skips. A PTS on the
// H.264 track is stamped at that start, so a client measuring from PTS adds
// this to get the same arrival reference the HEVC track's PTS has.
final class LatencyLog {
    private let lock = NSLock()
    private var waits: [Double] = []

    init() {
        let start = t0
        let now = DispatchTime.now().uptimeNanoseconds
        let wall = Date().timeIntervalSince1970 * 1e6 - Double(now - start) / 1000
        log("latency: t0 wall \(UInt64(wall)) us")
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in self?.report() }
        timer.resume()
        _ = Unmanaged.passRetained(timer as AnyObject)
    }

    func note(_ arrived: UInt64) {
        let ms = Double(DispatchTime.now().uptimeNanoseconds - arrived) / 1e6
        lock.withLock { waits.append(ms) }
    }

    private func report() {
        let w = lock.withLock { () -> [Double] in defer { waits = [] }; return waits.sorted() }
        guard !w.isEmpty else { return }
        func p(_ q: Double) -> String { String(format: "%.1f", w[min(w.count - 1, Int(Double(w.count) * q))]) }
        log("latency: arrival to H.264 encode n=\(w.count) p50 \(p(0.5))ms p90 \(p(0.9))ms max \(p(1))ms")
    }
}

let latency: LatencyLog? = ProcessInfo.processInfo.environment["SIMCAP_LATENCY"] == "1" ? LatencyLog() : nil

// MARK: - passthrough

// HEVCPassthrough writes the phone's own access units to fd 3, in the wire
// format stdout uses (encoder.swift): a 64-byte name, "h265" and the size,
// then a 12-byte header per packet. Nothing is decoded or re-encoded, so a
// viewer that can decode HEVC skips both. A config packet carries VPS, SPS and
// PPS whenever they change, and every IRAP access unit carries them in front
// as well, so the stream decodes from any keyframe on its own. The PTS is when
// the access unit's first packet arrived, on the same clock as the H.264
// track's.
final class HEVCPassthrough {
    private let out = FileHandle(fileDescriptor: 3, closeOnDealloc: false)
    private var started = false
    private var lastParams = Data()
    private(set) var written = 0

    init() {
        if fcntl(3, F_GETFD) == -1 { fail("-hevc writes to fd 3, which is not open") }
    }

    private func write(_ d: Data) {
        do { try out.write(contentsOf: d) } catch { exit(0) } // the reader is gone
    }

    // au is the access unit's NAL units without start codes, parameter sets
    // and delimiters already taken out.
    func send(vps: Data, sps: Data, pps: Data, format: CMVideoFormatDescription, nals: [Data], key: Bool, pts: UInt64) {
        if !started {
            // A viewer cannot start mid-GOP, so neither does the stream.
            guard key else { return }
            started = true
            let dim = CMVideoFormatDescriptionGetDimensions(format)
            var name = Data(streamName.utf8.prefix(63))
            name += Data(count: 64 - name.count)
            write(name + be32(0x6832_3635) + be32(UInt32(dim.width)) + be32(UInt32(dim.height))) // "h265"
            log("hevc: passthrough \(dim.width)x\(dim.height) on fd 3")
        }
        let params = startCode + vps + startCode + sps + startCode + pps
        if params != lastParams {
            lastParams = params
            write(be64(flagConfig) + be32(UInt32(params.count)) + params)
        }
        var au = key ? params : Data()
        for n in nals { au += startCode + n }
        write(be64(pts | (key ? flagKey : 0)) + be32(UInt32(au.count)) + au)
        written += 1
    }
}

// MARK: - RTP in, HEVC out

final class WifiReceiver {
    let fd: Int32
    private let lock = NSLock()
    private var peer: sockaddr_in6?
    private var me: UInt32 = 0        // the Mac's negotiated SSRC
    private var remote: UInt32 = 0    // the phone's
    private var baseSeq = -1, maxSeq = 0, cycles = 0, received = 0
    private var lsr: UInt32 = 0, lsrAt: Date?
    private var lastPLI = Date.distantPast
    private var firSeq: UInt8 = 0
    private var askedAt: Date?        // the oldest unanswered keyframe ask
    private var loggedAsk = Date.distantPast

    // Owned by the receive thread.
    private var depack = HEVCDepacketizer()
    let passthrough: HEVCPassthrough? = hevcOut ? HEVCPassthrough() : nil
    private var vps: Data?, sps: Data?, pps: Data?
    private var format: CMVideoFormatDescription?
    private var decoder: VTDecompressionSession?
    var last: CVPixelBuffer?          // the newest decoded picture, on encodeQueue
    private var packets = 0, pictures = 0, keys = 0

    init?(ip: String, port: UInt16) {
        fd = socket(AF_INET6, SOCK_DGRAM, 0)
        // Something already holds the port by the time CoreDevice logs it,
        // and the bind fails without this. The scratchpad probe found that;
        // which process holds it is not established.
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, 4)
        var big: Int32 = 8 << 20
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &big, 4)
        var a = sockaddr_in6()
        a.sin6_family = sa_family_t(AF_INET6)
        a.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        a.sin6_port = port.bigEndian
        guard inet_pton(AF_INET6, ip, &a.sin6_addr) == 1 else {
            log("wifi: receiver address \(ip) is not IPv6")
            return nil
        }
        let r = withUnsafePointer(to: &a) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
        }
        if r != 0 {
            log("wifi: bind [\(ip)]:\(port): \(String(cString: strerror(errno)))")
            close(fd)
            return nil
        }
        log("wifi: receiving on [\(ip)]:\(port)")
    }

    func setSSRC(_ v: UInt32) {
        lock.lock()
        me = v
        lock.unlock()
    }

    func start() {
        Thread.detachNewThread { self.receive() }
        Thread.detachNewThread { self.reportLoop() }
    }

    private func receive() {
        var buf = [UInt8](repeating: 0, count: 65536)
        var from = sockaddr_in6()
        while true {
            var fl = socklen_t(MemoryLayout<sockaddr_in6>.size)
            let k = buf.withUnsafeMutableBytes { b in
                withUnsafeMutablePointer(to: &from) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, b.baseAddress, b.count, 0, $0, &fl) }
                }
            }
            if k <= 0 {
                if errno == EINTR { continue }
                fail("wifi: receive: \(String(cString: strerror(errno)))")
            }
            buf.withUnsafeBytes { packet(UnsafeRawBufferPointer(rebasing: $0[0..<k]), from) }
        }
    }

    private func packet(_ b: UnsafeRawBufferPointer, _ from: sockaddr_in6) {
        guard b.count >= 12, b[0] >> 6 == 2 else { return }
        // RTCP shares the port (RFC 5761): its second byte is 192-223.
        if b[1] >= 192 && b[1] <= 223 {
            if b[1] == 200 && b.count >= 20 {
                lock.lock()
                peer = from
                lsr = be32(b, 10)
                lsrAt = Date()
                lock.unlock()
            }
            return
        }
        let marker = b[1] >> 7 != 0
        let seq = be16(b, 2), ts = be32(b, 4)
        lock.lock()
        peer = from
        remote = be32(b, 8)
        received += 1
        if baseSeq < 0 {
            baseSeq = seq
            maxSeq = seq
        } else if (seq - maxSeq) & 0xffff < 0x8000 {
            if seq < maxSeq { cycles += 1 }
            maxSeq = seq
        }
        lock.unlock()
        packets += 1

        let r = depack.push(b, arrival: DispatchTime.now().uptimeNanoseconds)
        if let lost = r.lost { lose("packet \(lost) lost") }
        for u in r.units { decode(u) }
    }

    private var waiting = false
    private var keyShape = ""

    // noteKeyShape logs a keyframe's slice count, and whether parameter sets
    // came with it, when that changes. A picture split into several slices is
    // what a lost packet can leave half decoded.
    private func noteKeyShape(_ u: HEVCDepacketizer.Unit) {
        let types = u.nals.filter { $0.count >= 2 }.map { ($0[$0.startIndex] >> 1) & 0x3f }
        let shape = "\(types.filter { $0 < 32 }.count) slice(s), parameter sets \(types.contains(33) ? "with it" : "not repeated")"
        if shape != keyShape { log("wifi: keyframe: \(shape)") }
        keyShape = shape
    }

    // lose logs a failure once until the next picture decodes, and asks the
    // phone for a keyframe. The depacketiser already holds back what follows.
    private func lose(_ why: String) {
        if !waiting { log("wifi: \(why); waiting for a keyframe") }
        waiting = true
        sendPLI()
    }

    // decode decodes one whole access unit.
    private func decode(_ u: HEVCDepacketizer.Unit) {
        let key = u.key
        if key { noteKeyShape(u) }
        var params = false
        var body = Data()
        var picture: [Data] = []
        for n in u.nals where n.count >= 2 {
            let t = (n[n.startIndex] >> 1) & 0x3f
            switch t {
            case 32: if vps != n { vps = n; params = true }
            case 33: if sps != n { sps = n; params = true }
            case 34: if pps != n { pps = n; params = true }
            case 35: break // access unit delimiter
            default:
                body.append(contentsOf: bytes32(UInt32(n.count)))
                body.append(n)
                if passthrough != nil { picture.append(n) }
            }
        }
        if (params || format == nil) && makeDecoder() && !key {
            // A new decoder starts at an IRAP picture.
            depack.resync()
            return
        }
        guard !body.isEmpty, let format, let decoder else { return }
        waiting = false
        if let passthrough, let vps, let sps, let pps {
            // t0 first, as encodePixels reads it.
            let start = t0
            let pts = (max(u.arrival, start) - start) / 1000
            passthrough.send(vps: vps, sps: sps, pps: pps, format: format, nals: picture, key: key, pts: pts)
            if key {
                keys += 1
                answered()
            }
        }
        var block: CMBlockBuffer?
        let len = body.count
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: len, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: len, flags: 0,
                                                 blockBufferOut: &block) == noErr, let block else { return }
        _ = body.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: len) }
        var sbuf: CMSampleBuffer?
        var size = len
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
                                        sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1,
                                        sampleSizeArray: &size, sampleBufferOut: &sbuf) == noErr, let sbuf else { return }
        let arrived = u.arrival
        let st = VTDecompressionSessionDecodeFrame(decoder, sampleBuffer: sbuf, flags: [], infoFlagsOut: nil) { [weak self] st, _, pb, _, _ in
            guard let self else { return }
            if st != noErr || pb == nil {
                log("wifi: decode: \(st)")
                return
            }
            let pixels = pb!
            encodeQueue.async {
                if self.last == nil {
                    log("wifi: first picture \(CVPixelBufferGetWidth(pixels))x\(CVPixelBufferGetHeight(pixels))")
                }
                self.last = pixels
                if DispatchTime.now().uptimeNanoseconds - lastEncode >= minGap {
                    latency?.note(arrived)
                    encodePixels(pixels, 0)
                }
            }
        }
        if st != noErr {
            depack.resync()
            lose("decode \(st)")
        }
        pictures += 1
    }

    // makeDecoder makes a format from the parameter sets, and a decoder when
    // the one there cannot take it. It reports whether it made a decoder.
    @discardableResult
    private func makeDecoder() -> Bool {
        guard let vps, let sps, let pps else { return false }
        var desc: CMFormatDescription?
        let st = vps.withUnsafeBytes { v in sps.withUnsafeBytes { s in pps.withUnsafeBytes { p in
            let ptrs = [v, s, p].map { $0.bindMemory(to: UInt8.self).baseAddress! }
            let sizes = [vps.count, sps.count, pps.count]
            return CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: nil, parameterSetCount: 3,
                                                                       parameterSetPointers: ptrs, parameterSetSizes: sizes,
                                                                       nalUnitHeaderLength: 4, extensions: nil,
                                                                       formatDescriptionOut: &desc)
        } } }
        guard st == noErr, let desc else {
            log("wifi: HEVC parameter sets: \(st)")
            return false
        }
        if let decoder, VTDecompressionSessionCanAcceptFormatDescription(decoder, formatDescription: desc) {
            format = desc
            return false
        }
        if let decoder { VTDecompressionSessionInvalidate(decoder) }
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var s: VTDecompressionSession?
        let r = VTDecompressionSessionCreate(allocator: nil, formatDescription: desc, decoderSpecification: nil,
                                             imageBufferAttributes: attrs as CFDictionary, outputCallback: nil,
                                             decompressionSessionOut: &s)
        guard r == noErr, let s else {
            log("wifi: HEVC decoder: \(r)")
            return false
        }
        let dim = CMVideoFormatDescriptionGetDimensions(desc)
        log("wifi: HEVC \(dim.width)x\(dim.height)")
        format = desc
        decoder = s
        return true
    }

    // logPassthrough says how many access units and keyframes went out
    // since the last call, which is how often the phone sends an IRAP.
    private var loggedAU = 0, loggedKeys = 0
    func logPassthrough() {
        guard let passthrough else { return }
        let n = passthrough.written, k = keys
        log("hevc: \(n - loggedAU) access units, \(k - loggedKeys) keyframes in 5s")
        loggedAU = n
        loggedKeys = k
    }

    // MARK: RTCP out

    // reportLoop sends a receiver report and our SDES twice a second, under
    // the Mac's negotiated SSRC: the phone times the stream out after 15s
    // without them, and ignores them under any other SSRC.
    private func reportLoop() {
        var sent = 0
        while true {
            Thread.sleep(forTimeInterval: 0.5)
            lock.lock()
            guard let p = peer, remote != 0, me != 0 else {
                lock.unlock()
                continue
            }
            let ext = UInt32(cycles << 16 | maxSeq)
            let lost = max(0, Int(ext) - baseSeq + 1 - received)
            let dlsr: UInt32 = lsrAt.map { UInt32(Date().timeIntervalSince($0) * 65536) } ?? 0
            var pkt: [UInt8] = [0x81, 201, 0, 7] + bytes32(me) + bytes32(remote)
            pkt += [0] + Array(bytes32(UInt32(min(lost, 0xffffff))).dropFirst())
            pkt += bytes32(ext) + bytes32(0) + bytes32(lsr) + bytes32(dlsr)
            let cname = Array("loupe".utf8)
            var sdes: [UInt8] = bytes32(me) + [1, UInt8(cname.count)] + cname + [0]
            while sdes.count % 4 != 0 { sdes.append(0) }
            pkt += [0x81, 202, 0, UInt8(sdes.count / 4)] + sdes
            lock.unlock()
            send(pkt, to: p)
            sent += 1
            if sent == 1 { log("wifi: reporting as SSRC \(me) to SSRC \(remote)") }
        }
    }

    // requestKeyframe is a viewer's ask, through stdin's byte 17. The H.264
    // encoder makes its own; the passthrough has only the phone's.
    func requestKeyframe() {
        guard passthrough != nil else { return }
        sendPLI()
    }

    // sendPLI asks the phone for a keyframe, at most five times a second, as
    // both a PLI (RFC 4585) and a FIR (RFC 5104): which of them the phone
    // honours, if either, is what the ask and answer lines in the log find out.
    private func sendPLI() {
        lock.lock()
        guard let p = peer, remote != 0, me != 0, Date().timeIntervalSince(lastPLI) > 0.2 else {
            lock.unlock()
            return
        }
        lastPLI = Date()
        if askedAt == nil { askedAt = lastPLI }
        firSeq &+= 1
        let pli: [UInt8] = [0x81, 206, 0, 2] + bytes32(me) + bytes32(remote)
        let fir: [UInt8] = [0x84, 206, 0, 4] + bytes32(me) + bytes32(0) + bytes32(remote) + [firSeq, 0, 0, 0]
        let logIt = lastPLI.timeIntervalSince(loggedAsk) > 2
        if logIt { loggedAsk = lastPLI }
        lock.unlock()
        send(pli, to: p)
        send(fir, to: p)
        if logIt { log("wifi: asked the phone for a keyframe (PLI and FIR \(firSeq))") }
    }

    // answered logs how long the phone took to send a keyframe after an ask.
    private func answered() {
        lock.lock()
        let at = askedAt
        askedAt = nil
        lock.unlock()
        if let at { log("wifi: keyframe \(Int(Date().timeIntervalSince(at) * 1000))ms after the ask") }
    }

    private func send(_ pkt: [UInt8], to peer: sockaddr_in6) {
        var p = peer
        _ = pkt.withUnsafeBytes { b in
            withUnsafePointer(to: &p) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, b.baseAddress, b.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        }
    }
}

// MARK: - the session

// The layer CoreDevice's own receiver would draw into. Nothing draws into it
// here, since avconferenced refuses this process, but the configuration
// needs one.
private let wifiLayer = CALayer()
private var wifiReceiver: WifiReceiver?

func runPhoneWifi(identifier: String, name: String) -> Never {
    guard let want = UUID(uuidString: identifier) else {
        fail("-phone-wifi takes CoreDevice's identifier, a UUID, not \(identifier)")
    }
    let pending = NSLock()
    var ssrc: UInt32 = 0
    let watcher = watchNegotiation(receiver: { ip, port in
        guard let r = WifiReceiver(ip: ip, port: port) else { fail("wifi: cannot receive on [\(ip)]:\(port)") }
        pending.lock()
        if ssrc != 0 { r.setSSRC(ssrc) }
        wifiReceiver = r
        pending.unlock()
        r.start()
    }, ssrc: { v in
        pending.lock()
        ssrc = v
        wifiReceiver?.setSSRC(v)
        pending.unlock()
    })
    _ = watcher
    disableResolutionAdaptation()

    Task {
        guard let dev = await coreDevice(want) else { fail("CoreDevice does not list \(identifier)") }
        streamName = name.isEmpty ? identifier : name
        do {
            let session = MediaStreamSession(clientSessionID: UUID())
            let cfg = await MainActor.run { VideoStreamConfiguration.receiveMirroredPrimary(layer: wifiLayer, timeout: 15) }
            let stream = try await session.makeVideoStream(withConfiguration: cfg, fromRemoteDevice: dev)
            let events = try await stream.activate()
            log("wifi: media stream negotiated")
            for try await _ in events {}
            fail("wifi: the phone ended the media stream")
        } catch {
            fail("wifi: media stream: \(error)")
        }
    }
    // Nothing arrives at all is a negotiation that never reached the port.
    encodeQueue.asyncAfter(deadline: .now() + 20) {
        if wifiReceiver?.last == nil { fail("wifi: no picture from the phone in 20s") }
    }

    // The phone sends nothing while its screen is still, and the viewer
    // still needs a keyframe a second.
    let idle = DispatchSource.makeTimerSource(queue: encodeQueue)
    idle.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250))
    idle.setEventHandler {
        if let pb = wifiReceiver?.last, DispatchTime.now().uptimeNanoseconds - lastEncode >= 250_000_000 {
            encodePixels(pb, 0)
        }
    }
    idle.resume()
    if hevcOut {
        onKeyRequest = { wifiReceiver?.requestKeyframe() }
        let report = DispatchSource.makeTimerSource(queue: .global())
        report.schedule(deadline: .now() + 5, repeating: 5)
        report.setEventHandler { wifiReceiver?.logPassthrough() }
        report.resume()
        _ = Unmanaged.passRetained(report as AnyObject)
    }
    startControl()
    dispatchMain()
}

// disableResolutionAdaptation takes VRAE out of the feature list simcap's
// negotiator offers the phone. With it, the phone drops its encode size
// while the screen moves and rescales its reference pictures to match;
// avconferenced decodes that with private per-frame options, and every
// standard HEVC decoder, VideoToolbox's included, smears from the first
// reduced frame to the next keyframe.
func disableResolutionAdaptation() {
    _ = dlopen("/System/Library/PrivateFrameworks/AVConference.framework/AVConference", RTLD_NOW)
    let sel = NSSelectorFromString("featureListString")
    guard let cls = NSClassFromString("AVCMediaStreamNegotiatorSettingsCoreDeviceScreenSharing"),
          let m = class_getInstanceMethod(cls, sel) else {
        log("wifi: no negotiator settings class; resolution adaptation stays on")
        return
    }
    typealias Getter = @convention(c) (AnyObject, Selector) -> AnyObject?
    let orig = unsafeBitCast(method_getImplementation(m), to: Getter.self)
    var logged = false
    let patched: @convention(block) (AnyObject) -> AnyObject? = { me in
        guard let list = orig(me, sel) as? [AnyHashable: Any] else { return orig(me, sel) }
        var out = [AnyHashable: Any]()
        for (k, v) in list { out[k] = (v as? String)?.replacingOccurrences(of: "VRAE:0;", with: "") ?? v }
        if !logged { logged = true; log("wifi: offering features \(out)") }
        return out as NSDictionary
    }
    method_setImplementation(m, imp_implementationWithBlock(patched))
}
