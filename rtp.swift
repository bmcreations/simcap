import Foundation

// HEVCDepacketizer turns the phone's RTP video packets (RFC 7798) into whole
// access units, and holds back everything after a lost packet until an IRAP
// picture the decoder can start from. No sockets and no VideoToolbox, so the
// tests (tests/rtp_tests.swift, make test) drive it with packets they build.
struct HEVCDepacketizer {
    struct Unit: Equatable {
        var nals: [Data]
        var timestamp: UInt32
        // Uptime ns the unit's first packet arrived, as given to push.
        var arrival: UInt64
        // Holds an IRAP slice (NAL types 16-21).
        var key: Bool
    }

    struct Result: Equatable {
        // The units completed by this packet, at most two (the one a new
        // timestamp ended, and this packet's own if it has the marker).
        var units: [Unit] = []
        // The sequence number expected when this packet showed a gap.
        var lost: Int?
    }

    // True until the next IRAP: at the start, after a loss, after resync.
    private(set) var broken = true

    private var lastSeq = -1
    private var auTS: UInt32?
    // The access unit in progress lost a packet. It is dropped whole: a
    // keyframe missing a slice decodes, and every delta after it smears.
    private var auDamaged = false
    private var auArrival: UInt64 = 0
    private var nals: [Data] = []
    private var fu: Data?

    // resync drops everything up to the next IRAP, for a failure the
    // depacketiser cannot see (the decoder rejecting a picture).
    mutating func resync() {
        broken = true
        auDamaged = true
        fu = nil
        nals.removeAll()
    }

    // push takes one RTP packet (not RTCP) that arrived at uptime ns arrival.
    mutating func push(_ b: UnsafeRawBufferPointer, arrival: UInt64) -> Result {
        var r = Result()
        guard b.count >= 12, b[0] >> 6 == 2 else { return r }
        let marker = b[1] >> 7 != 0
        let seq = u16(b, 2), ts = u32(b, 4)

        var off = 12 + 4 * Int(b[0] & 0x0f)
        if b[0] & 0x10 != 0 {
            // A one-word header extension, profiles 0x9001 and 0x9011 on
            // bmc-iphone, not decoded.
            guard b.count >= off + 4 else { return r }
            off += 4 + 4 * u16(b, off + 2)
        }
        var end = b.count
        if b[0] & 0x20 != 0 { end -= Int(b[b.count - 1]) }
        guard end > off + 2 else { return r }

        let gap = lastSeq >= 0 && seq != (lastSeq + 1) & 0xffff
        if gap {
            // RTX and FEC are off in the negotiated config, so a lost
            // packet is gone. Everything up to the next IRAP is undecodable.
            r.lost = (lastSeq + 1) & 0xffff
            resync()
        }
        lastSeq = seq
        let p = UnsafeRawBufferPointer(rebasing: b[off..<end])
        let newAU = auTS != ts
        if let t = auTS, t != ts, let u = flush() { r.units.append(u) }
        if newAU {
            // After a gap, this picture is whole only if this packet is its
            // start; otherwise the lost packets were its first ones.
            auArrival = arrival
            auDamaged = gap && !startsPicture(p)
        }
        auTS = ts

        let type = (p[0] >> 1) & 0x3f
        switch type {
        case 48: // aggregation packet: u16 size, then that many bytes, repeated
            var i = 2
            while i + 2 <= p.count {
                let n = u16(p, i)
                guard i + 2 + n <= p.count else { break }
                nals.append(Data(p[(i + 2)..<(i + 2 + n)]))
                i += 2 + n
            }
        case 49: // fragmentation unit
            guard p.count > 3 else { return r }
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
        if marker, let u = flush() { r.units.append(u) }
        return r
    }

    // flush ends the access unit in progress, and returns it unless it has to
    // be dropped while broken.
    private mutating func flush() -> Unit? {
        defer { nals.removeAll(); auTS = nil; auDamaged = false }
        guard let ts = auTS, !nals.isEmpty, !auDamaged else { return nil }
        let key = nals.contains { $0.count >= 2 && (16...21).contains(($0[$0.startIndex] >> 1) & 0x3f) }
        if broken {
            guard key else { return nil }
            broken = false
        }
        return Unit(nals: nals, timestamp: ts, arrival: auArrival, key: key)
    }
}

// startsPicture reports whether an RTP payload begins an access unit:
// parameter sets, an access unit delimiter or a prefix SEI, or the first slice
// of a picture (first_slice_segment_in_pic_flag), on its own or in the first
// fragment of a fragmentation unit.
func startsPicture(_ p: UnsafeRawBufferPointer) -> Bool {
    guard p.count >= 3 else { return false }
    var t = (p[0] >> 1) & 0x3f
    var body = 2
    switch t {
    case 48:
        guard p.count >= 6 else { return false }
        t = (p[4] >> 1) & 0x3f
        body = 6
    case 49:
        guard p[2] & 0x80 != 0, p.count >= 4 else { return false }
        t = p[2] & 0x3f
        body = 3
    default:
        break
    }
    if (32...35).contains(t) || t == 39 { return true }
    return t < 32 && body < p.count && p[body] & 0x80 != 0
}

private func u16(_ b: UnsafeRawBufferPointer, _ i: Int) -> Int { Int(b[i]) << 8 | Int(b[i + 1]) }
private func u32(_ b: UnsafeRawBufferPointer, _ i: Int) -> UInt32 {
    UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])
}
