// Which surface to stream on a device with more than one panel, and when to
// hold back a black one. Foundation only, so `make test` can build it alone.
//
// On a fold the iPhone Duo's old panel goes solid black, both are black for
// 30-310ms, then the new one lights, and CoreDevice reports no single lit
// panel for part of that. Streaming the largest surface unturned meanwhile
// sent the inner panel sideways (1016x1440) for ~825ms, and each panel's
// black frames reached the viewer as a keyframe at the new size.

import Foundation

// LitDisplay is the panel in use. id is CoreDevice's displayId, which is
// also simctl's screen ID: on loupe-duo the outer panel is 1 and the inner 3.
// width and height are the framebuffer's, and turn is how far it is turned
// clockwise to stand upright (see PanelSpec).
struct LitDisplay: Equatable {
    var width: Int, height: Int, id: UInt32, turn: Int = 0
}

// PanelSpec is what the device type declares about one display. The Duo's
// inner panel has a nativeRotation of 270: its framebuffer is 2007x2853 while
// the Home Screen on it is landscape, and simctl's screenshot of it is
// 2853x2007. The picture is the framebuffer turned a quarter clockwise: the
// stream turned that way showed the Home Screen upright, and a tap at
// Settings' upright position, (1500,264), opened it. scale is pixels per point, which the accessibility tree
// needs because its root reports the outer panel even while the inner is lit.
// width and height are the framebuffer's, which is how a surface is matched
// to its panel: 1398x2034 and 2007x2853 on the Duo. id is its screenID,
// which a touch is aimed at.
struct PanelSpec {
    var turn: Int, scale: Double, width: Int = 0, height: Int = 0, id: UInt32 = 0
}

// Candidate is one framebuffer surface: its size, and whether it is solid
// black, asked only when the choice needs it.
struct Candidate {
    var width: Int, height: Int
    var black: () -> Bool = { false }
}

// litHoldNanos is how long a foldable keeps streaming its last lit panel
// while CoreDevice names none.
let litHoldNanos: UInt64 = 1_500_000_000

// chooseSurface picks the surface to stream and its turn. The lit panel wins
// when CoreDevice names one. With two or more panels and none named, the last
// lit one is held for litHoldNanos; after that, or with no last one, the guess
// is the one panel that is not black, else the largest, turned the way its
// panel declares. A device with one panel streams its largest surface
// unturned, as before.
//
// On two or more panels, a black choice gives way to the one other panel
// with a picture: the hidden panel is solid black, so a picture there means
// it has lit, and CoreDevice says so about 200ms later. A dark app on the
// lit panel leaves the other one black and keeps its place.
//
// id is the chosen panel's screenID, which input aims a touch at, or 0 when
// nothing names one (a phone before CoreDevice answers). A touch aimed by
// CoreDevice's lit panel instead landed on the old panel for up to 200ms
// after the new one showed.
func chooseSurface(_ cands: [Candidate], panels: Int, lit: LitDisplay?, lastLit: LitDisplay?,
                   unknownFor: UInt64, specs: [PanelSpec]) -> (index: Int, turn: Int, id: UInt32)? {
    func match(_ d: LitDisplay) -> Int? { cands.firstIndex { $0.width == d.width && $0.height == d.height } }
    func area(_ i: Int) -> Int { cands[i].width * cands[i].height }
    guard let largest = cands.indices.max(by: { area($0) < area($1) }) else { return nil }
    guard panels >= 2 else {
        if let lit, let i = match(lit) { return (i, lit.turn, lit.id) }
        return (largest, 0, lit?.id ?? 0)
    }
    func spec(_ i: Int) -> PanelSpec? { specs.first { $0.width == cands[i].width && $0.height == cands[i].height } }
    func bySpec(_ i: Int) -> (index: Int, turn: Int, id: UInt32) { (i, spec(i)?.turn ?? 0, spec(i)?.id ?? 0) }
    let panelIdx = cands.indices.filter { spec($0) != nil }
    var pick: (index: Int, turn: Int, id: UInt32)?
    if let lit, let i = match(lit) { pick = (i, lit.turn, lit.id) }
    else if let lastLit, unknownFor < litHoldNanos, let i = match(lastLit) { pick = (i, lastLit.turn, lastLit.id) }
    if let p = pick, !cands[p.index].black() { return p }
    let others = panelIdx.filter { $0 != pick?.index && !cands[$0].black() }
    if others.count == 1 { return bySpec(others[0]) }
    if let pick { return pick }
    return bySpec(panelIdx.max(by: { area($0) < area($1) }) ?? largest)
}

// blackSkipNanos caps how long black frames are held back after a switch, so
// an app that really is black still reaches the viewer.
let blackSkipNanos: UInt64 = 350_000_000

// skipBlack says whether a frame is held back: it is solid black and the
// switch window opened under blackSkipNanos ago.
func skipBlack(_ black: Bool, windowStart: UInt64?, now: UInt64) -> Bool {
    guard black, let start = windowStart, now >= start else { return false }
    return now - start < blackSkipNanos
}

// isSolidBlack samples a 32-bit-per-pixel buffer every step pixels each way
// and says whether every sample's colour channels are at most 8.
func isSolidBlack(_ base: UnsafeRawPointer, width: Int, height: Int, bytesPerRow: Int, step: Int = 23) -> Bool {
    let p = base.assumingMemoryBound(to: UInt8.self)
    var y = 0
    while y < height {
        var x = 0
        while x < width {
            let px = p + y * bytesPerRow + x * 4
            if px[0] > 8 || px[1] > 8 || px[2] > 8 { return false }
            x += step
        }
        y += step
    }
    return true
}
