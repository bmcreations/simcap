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

    // Depacketiser state, owned by the receive thread.
    private var lastSeq = -1
    private var auTS: UInt32?
    private var nals: [Data] = []
    private var fu: Data?
    private var broken = true         // drop until the next IRAP picture
    private var vps: Data?, sps: Data?, pps: Data?
    private var format: CMVideoFormatDescription?
    private var decoder: VTDecompressionSession?
    var last: CVPixelBuffer?          // the newest decoded picture, on encodeQueue
    private var packets = 0, pictures = 0

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

        var off = 12 + 4 * Int(b[0] & 0x0f)
        if b[0] & 0x10 != 0 {
            // A one-word header extension, profiles 0x9001 and 0x9011 on
            // bmc-iphone, not decoded.
            guard b.count >= off + 4 else { return }
            off += 4 + 4 * be16(b, off + 2)
        }
        var end = b.count
        if b[0] & 0x20 != 0 { end -= Int(b[b.count - 1]) }
        guard end > off + 2 else { return }

        if lastSeq >= 0 && seq != (lastSeq + 1) & 0xffff {
            // RTX and FEC are off in the negotiated config, so a lost
            // packet is gone. Everything up to the next IRAP is undecodable.
            lose("packet \(lastSeq + 1) lost")
        }
        lastSeq = seq
        if let t = auTS, t != ts { flush() }
        auTS = ts

        let p = UnsafeRawBufferPointer(rebasing: b[off..<end])
        let type = (p[0] >> 1) & 0x3f
        switch type {
        case 48: // aggregation packet: u16 size, then that many bytes, repeated
            var i = 2
            while i + 2 <= p.count {
                let n = be16(p, i)
                guard i + 2 + n <= p.count else { break }
                nals.append(Data(p[(i + 2)..<(i + 2 + n)]))
                i += 2 + n
            }
        case 49: // fragmentation unit
            guard p.count > 3 else { return }
            let h = p[2]
            if h & 0x80 != 0 {
                fu = Data([(p[0] & 0x81) | ((h & 0x3f) << 1), p[1]]) + Data(p[3...])
            } else if fu != nil {
                fu!.append(contentsOf: p[3...])
            }
            if h & 0x40 != 0, let f = fu {
                nals.append(f)
                fu = nil
            }
        default:
            nals.append(Data(p))
        }
        if marker { flush() }
    }

    private func lose(_ why: String) {
        if !broken { log("wifi: \(why); waiting for a keyframe") }
        broken = true
        fu = nil
        nals.removeAll()
        sendPLI()
    }

    // flush decodes one access unit.
    private func flush() {
        defer { nals.removeAll(); auTS = nil }
        guard !nals.isEmpty else { return }
        var key = false, params = false
        var body = Data()
        for n in nals where n.count >= 2 {
            let t = (n[n.startIndex] >> 1) & 0x3f
            switch t {
            case 32: if vps != n { vps = n; params = true }
            case 33: if sps != n { sps = n; params = true }
            case 34: if pps != n { pps = n; params = true }
            case 35: break // access unit delimiter
            default:
                if (16...21).contains(t) { key = true }
                body.append(contentsOf: bytes32(UInt32(n.count)))
                body.append(n)
            }
        }
        if params || format == nil { makeDecoder() }
        guard !body.isEmpty, let format, let decoder else { return }
        if broken {
            guard key else { return }
            broken = false
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
                if DispatchTime.now().uptimeNanoseconds - lastEncode >= minGap { encodePixels(pixels, 0) }
            }
        }
        if st != noErr { lose("decode \(st)") }
        pictures += 1
    }

    private func makeDecoder() {
        guard let vps, let sps, let pps else { return }
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
            return
        }
        if let decoder, VTDecompressionSessionCanAcceptFormatDescription(decoder, formatDescription: desc) {
            format = desc
            return
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
            return
        }
        let dim = CMVideoFormatDescriptionGetDimensions(desc)
        log("wifi: HEVC \(dim.width)x\(dim.height)")
        format = desc
        decoder = s
        broken = true
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

    // sendPLI asks the phone for a keyframe (RFC 4585), at most five times a
    // second. Whether the phone honours it is not yet known.
    private func sendPLI() {
        lock.lock()
        guard let p = peer, remote != 0, me != 0, Date().timeIntervalSince(lastPLI) > 0.2 else {
            lock.unlock()
            return
        }
        lastPLI = Date()
        let pkt: [UInt8] = [0x81, 206, 0, 2] + bytes32(me) + bytes32(remote)
        lock.unlock()
        send(pkt, to: p)
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
    startControl()
    dispatchMain()
}
