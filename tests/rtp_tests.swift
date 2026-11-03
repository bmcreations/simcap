import Foundation

// make test: HEVCDepacketizer (rtp.swift) against RTP streams built here the
// way the phone sends them (RFC 7798): multi-slice pictures, parameter sets
// in an aggregation packet, big slices in fragmentation units.

// MARK: - Building streams

typealias Picture = [Data]

// nal is an HEVC NAL unit of type t. For a slice, first marks the first slice
// of its picture (first_slice_segment_in_pic_flag, the payload's top bit).
func nal(_ t: UInt8, first: Bool = false, size: Int = 40, fill: UInt8 = 0) -> Data {
    var d = Data([t << 1, 1, first ? 0x80 : 0x00])
    for i in 0..<max(0, size - 3) { d.append(UInt8((i &+ Int(fill)) & 0xff)) }
    return d
}

// picture is one access unit of slices slice NALs, sliceSize bytes each. A key
// picture is IDR_W_RADL (19) with VPS/SPS/PPS before it, a delta TRAIL_R (1).
func picture(key: Bool, slices: Int = 4, sliceSize: Int = 3000, fill: UInt8 = 0) -> Picture {
    var p: Picture = key ? [nal(32, size: 24), nal(33, size: 40), nal(34, size: 8)] : []
    for s in 0..<slices { p.append(nal(key ? 19 : 1, first: s == 0, size: sliceSize, fill: fill &+ UInt8(s))) }
    return p
}

// gops is n key pictures, each followed by deltas delta pictures, all distinct.
func gops(_ n: Int, deltas: Int = 3, slices: Int = 4) -> [Picture] {
    var out: [Picture] = []
    var f: UInt8 = 0
    for _ in 0..<n {
        out.append(picture(key: true, slices: slices, fill: f)); f &+= 7
        for _ in 0..<deltas { out.append(picture(key: false, slices: slices, fill: f)); f &+= 7 }
    }
    return out
}

struct Packet {
    var bytes: [UInt8]
    var picture: Int   // index of the picture it carries part of
}

// packetize sends pictures as RTP: parameter sets aggregated, NALs over mtu
// fragmented, the marker on each picture's last packet.
func packetize(_ pics: [Picture], seq start: Int = 1000, mtu: Int = 1200,
               ext: Bool = false, pad: Int = 0) -> [Packet] {
    var out: [Packet] = []
    var seq = start
    for (i, pic) in pics.enumerated() {
        var payloads: [[UInt8]] = []
        let params = pic.filter { (32...34).contains(($0[0] >> 1) & 0x3f) }
        if !params.isEmpty {
            var ap: [UInt8] = [48 << 1, 1]
            for n in params { ap += [UInt8(n.count >> 8), UInt8(n.count & 0xff)] + [UInt8](n) }
            payloads.append(ap)
        }
        for n in pic where !(32...34).contains((n[0] >> 1) & 0x3f) {
            let b = [UInt8](n)
            if b.count <= mtu { payloads.append(b); continue }
            let t = (b[0] >> 1) & 0x3f
            var o = 2
            while o < b.count {
                let k = min(mtu, b.count - o)
                var h = t
                if o == 2 { h |= 0x80 }
                if o + k == b.count { h |= 0x40 }
                payloads.append([(b[0] & 0x81) | (49 << 1), b[1], h] + Array(b[o..<(o + k)]))
                o += k
            }
        }
        for (j, pl) in payloads.enumerated() {
            let last = j == payloads.count - 1
            var h: [UInt8] = [0x80 | (ext ? 0x10 : 0) | (pad > 0 ? 0x20 : 0), (last ? 0x80 : 0) | 96,
                              UInt8(seq >> 8 & 0xff), UInt8(seq & 0xff)]
            let ts = UInt32(i * 1500)
            h += [UInt8(ts >> 24), UInt8(ts >> 16 & 0xff), UInt8(ts >> 8 & 0xff), UInt8(ts & 0xff), 0xde, 0xad, 0xbe, 0xef]
            if ext { h += [0x90, 0x01, 0, 1, 1, 2, 3, 4] }
            var p = h + pl
            if pad > 0 { p += [UInt8](repeating: 0, count: pad - 1) + [UInt8(pad)] }
            out.append(Packet(bytes: p, picture: i))
            seq = (seq + 1) & 0xffff
        }
    }
    return out
}

struct Run {
    var units: [HEVCDepacketizer.Unit] = []
    var losses = 0
}

func run(_ packets: [Packet], resyncBefore: Int? = nil) -> Run {
    var d = HEVCDepacketizer()
    var r = Run()
    for (i, p) in packets.enumerated() {
        if i == resyncBefore { d.resync() }
        let res = p.bytes.withUnsafeBytes { d.push($0, arrival: UInt64(i)) }
        r.units += res.units
        if res.lost != nil { r.losses += 1 }
    }
    return r
}

// MARK: - Checks

var failures = 0
var current = ""

func check(_ ok: Bool, _ what: @autoclosure () -> String, line: Int = #line) {
    if !ok {
        failures += 1
        print("FAIL \(current) (line \(line)): \(what())")
    }
}

// emitted lists which input picture each unit is, checking each is one of
// them exactly: a unit missing a slice or a fragment is a failure.
func emitted(_ r: Run, _ pics: [Picture]) -> [Int] {
    r.units.map { u in
        guard let i = pics.firstIndex(of: u.nals) else {
            check(false, "unit at ts \(u.timestamp) is not a whole input picture (\(u.nals.count) NALs)")
            return -1
        }
        check(u.key == (pics[i].first.map { (($0[0] >> 1) & 0x3f) == 32 } ?? false), "picture \(i) key flag")
        check(u.timestamp == UInt32(i * 1500), "picture \(i) timestamp \(u.timestamp)")
        return i
    }
}

func test(_ name: String, _ body: () -> Void) {
    current = name
    let before = failures
    body()
    print(failures == before ? "ok   \(name)" : "---- \(name)")
}

// dropping removes the packets at the given offsets within picture pic.
func dropping(_ packets: [Packet], picture pic: Int, at offsets: [Int]) -> [Packet] {
    let idx = packets.indices.filter { packets[$0].picture == pic }
    let gone = Set(offsets.map { idx[$0] })
    return packets.indices.filter { !gone.contains($0) }.map { packets[$0] }
}

// MARK: - Tests

@main
struct Tests {
    static func main() {
        test("a clean stream comes out picture for picture") {
            let pics = gops(2)
            let r = run(packetize(pics))
            check(emitted(r, pics) == Array(pics.indices), "got \(emitted(r, pics))")
            check(r.losses == 0, "losses \(r.losses)")
        }

        test("deltas before the first keyframe are dropped") {
            let pics = [picture(key: false, fill: 1), picture(key: false, fill: 2)] + gops(1)
            let r = run(packetize(pics))
            check(emitted(r, pics) == [2, 3, 4, 5], "got \(emitted(r, pics))")
        }

        test("a loss inside a delta drops it and the deltas after it, up to the next keyframe") {
            let pics = gops(2)
            let r = run(dropping(packetize(pics), picture: 1, at: [5]))
            check(emitted(r, pics) == [0, 4, 5, 6, 7], "got \(emitted(r, pics))")
            check(r.losses == 1, "losses \(r.losses)")
        }

        test("a loss inside a keyframe's later slice drops that keyframe and waits for the next") {
            let pics = gops(3)
            let r = run(dropping(packetize(pics), picture: 4, at: [7]))
            check(emitted(r, pics) == [0, 1, 2, 3, 8, 9, 10, 11], "got \(emitted(r, pics))")
        }

        test("losing a keyframe's first packets drops the slices that did arrive") {
            let pics = gops(3)
            // The aggregation packet (VPS/SPS/PPS) and the first slice's first fragment.
            let r = run(dropping(packetize(pics), picture: 4, at: [0, 1]))
            check(emitted(r, pics) == [0, 1, 2, 3, 8, 9, 10, 11], "got \(emitted(r, pics))")
        }

        test("a keyframe after a wholly lost picture is kept") {
            let pics = gops(2)
            let pk = packetize(pics)
            let n = pk.filter { $0.picture == 3 }.count
            let r = run(dropping(pk, picture: 3, at: Array(0..<n)))
            check(emitted(r, pics) == [0, 1, 2, 4, 5, 6, 7], "got \(emitted(r, pics))")
        }

        test("a lost marker packet drops its picture and keeps the keyframe after it") {
            let pics = gops(2)
            let pk = packetize(pics)
            let n = pk.filter { $0.picture == 3 }.count
            let r = run(dropping(pk, picture: 3, at: [n - 1]))
            check(emitted(r, pics) == [0, 1, 2, 4, 5, 6, 7], "got \(emitted(r, pics))")
        }

        test("sequence numbers wrapping past 65535 are not a loss") {
            let pics = gops(2)
            let r = run(packetize(pics, seq: 65530))
            check(emitted(r, pics) == Array(pics.indices), "got \(emitted(r, pics))")
            check(r.losses == 0, "losses \(r.losses)")
        }

        test("a header extension and padding are skipped") {
            let pics = gops(1)
            let r = run(packetize(pics, ext: true, pad: 4))
            check(emitted(r, pics) == Array(pics.indices), "got \(emitted(r, pics))")
        }

        test("single-slice pictures in single NAL packets") {
            let pics = (0..<6).map { picture(key: $0 % 3 == 0, slices: 1, sliceSize: 300, fill: UInt8($0)) }
            let r = run(packetize(pics))
            check(emitted(r, pics) == Array(pics.indices), "got \(emitted(r, pics))")
        }

        test("resync drops deltas until the next keyframe") {
            let pics = gops(2)
            let pk = packetize(pics)
            let at = pk.firstIndex { $0.picture == 2 }!
            let r = run(pk, resyncBefore: at)
            check(emitted(r, pics) == [0, 1, 4, 5, 6, 7], "got \(emitted(r, pics))")
        }

        test("a unit's arrival is its first packet's") {
            let pics = gops(1)
            let pk = packetize(pics)
            let r = run(pk)
            for u in r.units {
                let i = Int(u.timestamp) / 1500
                check(u.arrival == UInt64(pk.firstIndex { $0.picture == i }!), "picture \(i) arrival \(u.arrival)")
            }
        }

        print(failures == 0 ? "all passed" : "\(failures) failure(s)")
        exit(failures == 0 ? 0 : 1)
    }
}
