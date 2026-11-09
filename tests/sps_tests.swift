import Foundation

// make test: spsNoReorder (sps.swift) on SPS NALs VideoToolbox wrote on this
// Mac for a 664x1440 High-profile stream.

func hex(_ s: String) -> Data {
    var d = Data()
    var i = s.startIndex
    while i < s.endIndex {
        let j = s.index(i, offsetBy: 2)
        d.append(UInt8(s[i..<j], radix: 16)!)
        i = j
    }
    return d
}

func str(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

@main
struct SPSTests {
    static var failures = 0
    static func check(_ ok: Bool, _ what: String) {
        if !ok { failures += 1; print("FAIL", what) }
    }

    static func main() {
        // Remote settings (no low-latency rate control, Quality): no VUI.
        // The expected output was checked with ffmpeg's trace_headers
        // (max_num_reorder_frames 0, max_dec_frame_buffering 1, crop kept)
        // and decodes all 30 frames of the stream it came from.
        let remote = hex("27640028ac5680a80b5e5d")
        check(spsNoReorder(remote).map(str) == "27640028ac5680a80b5e5e01b41108d4", "remote SPS gains a no-reorder VUI")

        // An SPS that already has a VUI is left alone.
        if let fixed = spsNoReorder(remote) {
            check(spsNoReorder(fixed) == nil, "rewritten SPS is not rewritten again")
        }

        // Not an SPS (a PPS, type 8), or cut short: left alone.
        check(spsNoReorder(hex("28ee3cb0")) == nil, "PPS untouched")
        check(spsNoReorder(hex("27640028ac")) == nil, "truncated SPS untouched")

        print(failures == 0 ? "sps: all passed" : "sps: \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
