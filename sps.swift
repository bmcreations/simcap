import Foundation

// spsNoReorder returns an H.264 SPS NAL (header byte included, emulation
// prevention bytes in place) rewritten to say pictures come out in decode
// order: a VUI with bitstream_restriction, max_num_reorder_frames 0 and
// max_dec_frame_buffering 1. It returns nil, leaving the SPS as it is, when
// the SPS already has a VUI or is not one it can parse.
//
// The remote encoder runs without low-latency rate control, and without it
// VideoToolbox writes an SPS with no VUI. A decoder must then assume up to
// MaxDpbFrames pictures of reordering (8 at 664x1440, level 4.0) and may hold
// that many before output. Safari's WebCodecs decoder does, so a phone
// browser drew each frame 8 frames late and, with frames gated on its acks,
// stalled. VTDecompressionSession, which the iOS app uses, does not wait.
func spsNoReorder(_ nal: Data) -> Data? {
    let b = [UInt8](nal)
    guard b.count > 4, b[0] & 0x1f == 7 else { return nil }
    var rbsp: [UInt8] = []
    var zeros = 0
    for x in b.dropFirst() {
        if zeros >= 2 && x == 3 { zeros = 0; continue }
        rbsp.append(x)
        zeros = x == 0 ? zeros + 1 : 0
    }
    var r = BitReader(rbsp)
    guard let profile = r.bits(8), r.bits(16) != nil, r.ue() != nil else { return nil }
    if [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135].contains(profile) {
        guard let chroma = r.ue() else { return nil }
        if chroma == 3 { guard r.bits(1) != nil else { return nil } }
        guard r.ue() != nil, r.ue() != nil, r.bits(1) != nil, let scaling = r.bits(1) else { return nil }
        if scaling != 0 { return nil }  // scaling lists: not written by VideoToolbox here
    }
    guard r.ue() != nil, let poc = r.ue() else { return nil }
    if poc == 0 {
        guard r.ue() != nil else { return nil }
    } else if poc == 1 {
        guard r.bits(1) != nil, r.se() != nil, r.se() != nil, let n = r.ue() else { return nil }
        for _ in 0..<n { guard r.se() != nil else { return nil } }
    }
    guard r.ue() != nil, r.bits(1) != nil, r.ue() != nil, r.ue() != nil, let frameOnly = r.bits(1) else { return nil }
    if frameOnly == 0 { guard r.bits(1) != nil else { return nil } }
    guard r.bits(1) != nil, let crop = r.bits(1) else { return nil }
    if crop != 0 { for _ in 0..<4 { guard r.ue() != nil else { return nil } } }
    let at = r.pos
    guard let vui = r.bits(1), vui == 0 else { return nil }

    var w = BitWriter()
    for i in 0..<at { w.bit(Int(rbsp[i / 8] >> (7 - UInt8(i % 8)) & 1)) }
    w.bit(1)                       // vui_parameters_present_flag
    for _ in 0..<8 { w.bit(0) }    // aspect, overscan, signal, chroma loc, timing, nal hrd, vcl hrd, pic_struct
    w.bit(1)                       // bitstream_restriction_flag
    w.bit(1)                       // motion_vectors_over_pic_boundaries_flag
    w.ue(2); w.ue(1)               // max_bytes_per_pic_denom, max_bits_per_mb_denom (defaults)
    w.ue(16); w.ue(16)             // log2_max_mv_length horizontal, vertical (defaults)
    w.ue(0)                        // max_num_reorder_frames
    w.ue(1)                        // max_dec_frame_buffering
    w.bit(1)                       // rbsp_stop_one_bit
    while w.count % 8 != 0 { w.bit(0) }

    var out = Data([b[0]])
    zeros = 0
    for x in w.bytes {
        if zeros >= 2 && x <= 3 { out.append(3); zeros = 0 }
        out.append(x)
        zeros = x == 0 ? zeros + 1 : 0
    }
    return out
}

struct BitReader {
    let b: [UInt8]
    var pos = 0
    init(_ b: [UInt8]) { self.b = b }
    mutating func bits(_ n: Int) -> Int? {
        var v = 0
        for _ in 0..<n {
            guard pos < b.count * 8 else { return nil }
            v = v << 1 | Int(b[pos / 8] >> (7 - UInt8(pos % 8)) & 1)
            pos += 1
        }
        return v
    }
    mutating func ue() -> Int? {
        var lead = 0
        while true {
            guard let x = bits(1) else { return nil }
            if x == 1 { break }
            lead += 1
            if lead > 31 { return nil }
        }
        guard let rest = bits(lead) else { return nil }
        return (1 << lead) - 1 + rest
    }
    mutating func se() -> Int? {
        guard let k = ue() else { return nil }
        return k % 2 == 1 ? (k + 1) / 2 : -(k / 2)
    }
}

struct BitWriter {
    var bytes: [UInt8] = []
    var count = 0
    mutating func bit(_ v: Int) {
        if count % 8 == 0 { bytes.append(0) }
        if v != 0 { bytes[bytes.count - 1] |= 1 << (7 - UInt8(count % 8)) }
        count += 1
    }
    mutating func ue(_ v: Int) {
        let x = v + 1
        let n = Int.bitWidth - x.leadingZeroBitCount
        for _ in 0..<(n - 1) { bit(0) }
        for i in stride(from: n - 1, through: 0, by: -1) { bit(x >> i & 1) }
    }
}
