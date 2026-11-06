import Foundation

// make test: a foldable's surface choice and black-frame window (panels.swift),
// with the iPhone Duo's two panels.

var failures = 0
func check(_ ok: Bool, _ what: @autoclosure () -> String, line: Int = #line) {
    if !ok { failures += 1; print("FAIL line \(line): \(what())") }
}

let cover = LitDisplay(width: 1398, height: 2034, id: 1, turn: 0)
let inner = LitDisplay(width: 2007, height: 2853, id: 3, turn: 90)
let duoSpecs = [PanelSpec(turn: 0, scale: 3, width: 1398, height: 2034),
                PanelSpec(turn: 90, scale: 3, width: 2007, height: 2853)]
let ms: UInt64 = 1_000_000

// duo is the Duo's two surfaces, inner first as CoreSimulator lists them.
func duo(innerBlack: Bool = false, coverBlack: Bool = false) -> [Candidate] {
    [Candidate(width: 2007, height: 2853, black: { innerBlack }),
     Candidate(width: 1398, height: 2034, black: { coverBlack })]
}

func pick(_ c: [Candidate], panels: Int = 2, lit: LitDisplay?, last: LitDisplay?, unknownFor: UInt64 = 0)
    -> (w: Int, h: Int, turn: Int)? {
    chooseSurface(c, panels: panels, lit: lit, lastLit: last, unknownFor: unknownFor, specs: duoSpecs)
        .map { (c[$0.index].width, c[$0.index].height, $0.turn) }
}

@main
struct PanelsTests {
    static func main() {
        // The lit panel wins.
        var p = pick(duo(), lit: inner, last: cover)
        check(p?.w == 2007 && p?.turn == 90, "lit inner: \(String(describing: p))")
        p = pick(duo(), lit: cover, last: inner)
        check(p?.w == 1398 && p?.turn == 0, "lit cover: \(String(describing: p))")

        // Lit unknown mid-fold: hold the last lit panel, even the smaller one.
        p = pick(duo(innerBlack: true, coverBlack: true), lit: nil, last: cover, unknownFor: 800 * ms)
        check(p?.w == 1398 && p?.turn == 0, "hold cover: \(String(describing: p))")
        p = pick(duo(innerBlack: true, coverBlack: true), lit: nil, last: inner, unknownFor: 1499 * ms)
        check(p?.w == 2007 && p?.turn == 90, "hold inner: \(String(describing: p))")

        // Past the hold: the one panel that is not black, turned its own way.
        p = pick(duo(coverBlack: true), lit: nil, last: cover, unknownFor: 1500 * ms)
        check(p?.w == 2007 && p?.turn == 90, "guess inner: \(String(describing: p))")
        p = pick(duo(innerBlack: true), lit: nil, last: inner, unknownFor: 2000 * ms)
        check(p?.w == 1398 && p?.turn == 0, "guess cover: \(String(describing: p))")

        // Never the largest unturned: both black, or no last panel, still turns it.
        p = pick(duo(innerBlack: true, coverBlack: true), lit: nil, last: cover, unknownFor: 3000 * ms)
        check(p?.w == 2007 && p?.turn == 90, "both black: \(String(describing: p))")
        p = pick(duo(), lit: nil, last: nil)
        check(p?.w == 2007 && p?.turn == 90, "no last, both lit: \(String(describing: p))")
        p = pick(duo(innerBlack: true), lit: nil, last: nil)
        check(p?.w == 1398 && p?.turn == 0, "no last, cover lit: \(String(describing: p))")

        // A black choice gives way to the other panel once it has a picture,
        // before CoreDevice says so; a dark app with the other panel black stays.
        p = pick(duo(coverBlack: true), lit: cover, last: cover)
        check(p?.w == 2007 && p?.turn == 90, "stale lit cover, inner lit: \(String(describing: p))")
        p = pick(duo(innerBlack: true), lit: nil, last: inner, unknownFor: 100 * ms)
        check(p?.w == 1398 && p?.turn == 0, "held inner black, cover lit: \(String(describing: p))")
        p = pick(duo(innerBlack: true, coverBlack: true), lit: inner, last: inner)
        check(p?.w == 2007 && p?.turn == 90, "dark app on inner: \(String(describing: p))")
        p = pick(duo(innerBlack: true, coverBlack: true), lit: nil, last: cover, unknownFor: 100 * ms)
        check(p?.w == 1398 && p?.turn == 0, "both black, hold cover: \(String(describing: p))")

        // A last panel whose surface is gone falls through to the guess.
        p = pick([Candidate(width: 2007, height: 2853)], lit: nil, last: cover, unknownFor: 100 * ms)
        check(p?.w == 2007 && p?.turn == 90, "held surface gone: \(String(describing: p))")

        // One panel: the largest surface, unturned, as before.
        let phone = [Candidate(width: 720, height: 480), Candidate(width: 1206, height: 2622)]
        let one = chooseSurface(phone, panels: 1, lit: nil, lastLit: nil, unknownFor: 0, specs: [])
        check(one?.index == 1 && one?.turn == 0, "one panel: \(String(describing: one))")
        check(chooseSurface([], panels: 2, lit: nil, lastLit: cover, unknownFor: 0, specs: duoSpecs) == nil, "no surfaces")

        // Black frames are held back for under 350ms of a switch, then pass.
        check(skipBlack(true, windowStart: 1000 * ms, now: 1000 * ms), "black at switch")
        check(skipBlack(true, windowStart: 1000 * ms, now: 1349 * ms), "black at 349ms")
        check(!skipBlack(true, windowStart: 1000 * ms, now: 1350 * ms), "black at 350ms passes")
        check(!skipBlack(false, windowStart: 1000 * ms, now: 1100 * ms), "picture in window passes")
        check(!skipBlack(true, windowStart: nil, now: 1100 * ms), "black with no switch passes")

        // isSolidBlack over BGRA rows with padding.
        let w = 100, h = 60, bpr = w * 4 + 32
        var buf = [UInt8](repeating: 0, count: bpr * h)
        for i in stride(from: 3, to: buf.count, by: 4) { buf[i] = 255 }   // alpha does not count
        check(buf.withUnsafeBytes { isSolidBlack($0.baseAddress!, width: w, height: h, bytesPerRow: bpr) }, "black buffer")
        buf[46 * bpr + 46 * 4 + 1] = 200                                   // one sampled pixel, (46,46)
        check(!buf.withUnsafeBytes { isSolidBlack($0.baseAddress!, width: w, height: h, bytesPerRow: bpr) }, "lit pixel")
        buf[46 * bpr + 46 * 4 + 1] = 8
        check(buf.withUnsafeBytes { isSolidBlack($0.baseAddress!, width: w, height: h, bytesPerRow: bpr) }, "near black")

        print(failures == 0 ? "panels: all passed" : "panels: \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
