import Foundation

// make test: a foldable's surface choice and black-frame window (panels.swift),
// with the iPhone Duo's two panels.

var failures = 0
func check(_ ok: Bool, _ what: @autoclosure () -> String, line: Int = #line) {
    if !ok { failures += 1; print("FAIL line \(line): \(what())") }
}

let cover = LitDisplay(width: 1398, height: 2034, id: 1, turn: 0)
let inner = LitDisplay(width: 2007, height: 2853, id: 3, turn: 90)
let duoSpecs = [PanelSpec(turn: 0, scale: 3, width: 1398, height: 2034, id: 1),
                PanelSpec(turn: 90, scale: 3, width: 2007, height: 2853, id: 3)]
let ms: UInt64 = 1_000_000

// duo is the Duo's two surfaces, inner first as CoreSimulator lists them.
func duo(innerBlack: Bool = false, coverBlack: Bool = false) -> [Candidate] {
    [Candidate(width: 2007, height: 2853, black: { innerBlack }),
     Candidate(width: 1398, height: 2034, black: { coverBlack })]
}

func pick(_ c: [Candidate], panels: Int = 2, lit: LitDisplay?, last: LitDisplay?, unknownFor: UInt64 = 0)
    -> (w: Int, h: Int, turn: Int, id: UInt32)? {
    chooseSurface(c, panels: panels, lit: lit, lastLit: last, unknownFor: unknownFor, specs: duoSpecs)
        .map { (c[$0.index].width, c[$0.index].height, $0.turn, $0.id) }
}

// fixturePanels reads `devicectl device info displays --json-output` the way
// pollLit reads CoreDevice's display list.
func fixturePanels(_ name: String) -> [PanelState] {
    let url = URL(fileURLWithPath: "tests/fixtures/\(name).json")
    guard let data = try? Data(contentsOf: url),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let displays = (root["result"] as? [String: Any])?["displays"] as? [[String: Any]]
    else { return [] }
    return displays.filter { ($0["type"] as? [String: Any])?["integrated"] != nil }.map { d in
        let size = d["nativeSize"] as? [Double] ?? [0, 0]
        return PanelState(id: (d["displayId"] as? NSNumber)?.uint32Value ?? 0,
                          width: Int(size[0]), height: Int(size[1]),
                          active: d["active"] as? Bool ?? false,
                          backlit: (d["backlightState"] as? String ?? "").hasPrefix("active"))
    }
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
        check(one?.index == 1 && one?.turn == 0 && one?.id == 0, "one panel: \(String(describing: one))")
        let phoneLit = LitDisplay(width: 1206, height: 2622, id: 1)
        let oneLit = chooseSurface(phone, panels: 1, lit: phoneLit, lastLit: nil, unknownFor: 0, specs: [])
        check(oneLit?.index == 1 && oneLit?.id == 1, "one panel, lit: \(String(describing: oneLit))")

        // The panel a touch is aimed at is the one streamed, not the one
        // CoreDevice names: each case above, by id.
        check(pick(duo(), lit: inner, last: cover)?.id == 3, "lit inner id")
        check(pick(duo(), lit: cover, last: inner)?.id == 1, "lit cover id")
        check(pick(duo(coverBlack: true), lit: cover, last: cover)?.id == 3, "stale lit cover, inner lit: id")
        check(pick(duo(innerBlack: true), lit: inner, last: inner)?.id == 1, "stale lit inner, cover lit: id")
        check(pick(duo(innerBlack: true), lit: nil, last: inner, unknownFor: 100 * ms)?.id == 1, "held inner black, cover lit: id")
        check(pick(duo(innerBlack: true, coverBlack: true), lit: nil, last: cover, unknownFor: 100 * ms)?.id == 1, "both black, hold cover: id")
        check(pick(duo(innerBlack: true, coverBlack: true), lit: nil, last: cover, unknownFor: 3000 * ms)?.id == 3, "both black, guess: id")
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

        // LitPicker, by the backlight, with the flags the Duo showed on
        // 2026-11-17 (open and close through loupe, devicectl every ~85ms).
        let closedDuo = fixturePanels("duo-active-flag-stuck")
        check(closedDuo.count == 2, "fixture panels: \(closedDuo.count)")
        var lp = LitPicker()
        check(lp.pick(closedDuo, now: 0)?.id == 1, "closed Duo, active flag on the inner panel: outer")
        func panels(outer: (Bool, Bool), inner: (Bool, Bool)) -> [PanelState] {
            [PanelState(id: 1, width: 1398, height: 2034, active: outer.0, backlit: outer.1),
             PanelState(id: 3, width: 2007, height: 2853, active: inner.0, backlit: inner.1)]
        }
        // Open: the outer backlight goes off as the inner one comes on.
        check(lp.pick(panels(outer: (false, false), inner: (true, true)), now: 5_600 * ms)?.id == 3, "opened")
        // Close: both backlit for ~3.4s, the outer one newest.
        check(lp.pick(panels(outer: (false, true), inner: (true, true)), now: 11_800 * ms)?.id == 1, "closing, both backlit")
        check(lp.pick(panels(outer: (false, true), inner: (true, true)), now: 14_000 * ms)?.id == 1, "closing, still both")
        check(lp.pick(panels(outer: (false, true), inner: (true, false)), now: 15_200 * ms)?.id == 1, "closed")
        // A process starting mid-close sees both at once: the active one.
        lp = LitPicker()
        check(lp.pick(panels(outer: (false, true), inner: (true, true)), now: 0)?.id == 3, "both on in the first read: active")
        check(lp.pick(panels(outer: (false, true), inner: (true, false)), now: 3_400 * ms)?.id == 1, "then closed")
        // Two on together and neither active, or none backlit: no lit panel.
        lp = LitPicker()
        check(lp.pick(panels(outer: (false, true), inner: (false, true)), now: 0) == nil, "two backlit, none active")
        check(lp.pick(panels(outer: (true, false), inner: (true, false)), now: 0) == nil, "none backlit")

        print(failures == 0 ? "panels: all passed" : "panels: \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
