// Which framebuffer is lit. A phone has one display, but the iPhone Duo has
// two, an outer 1398x2034 panel and an inner 2007x2853 one, and both
// framebuffers stay allocated whichever is in use: folded, the inner one
// holds a black frame. The surfaces themselves cannot say which is lit, and
// SimScreen's power state reads On for both, so this asks CoreDevice, whose
// display list marks the lit panel `active` with its backlight `activeOn`.
//
// A display is matched to its framebuffer by size. The Duo's two panels
// differ, and a device with one display never needs the match.
//
// A read took 10ms, then 1ms, on loupe-duo (iPhone Duo, iOS 27.1), so it is
// polled rather than subscribed to.

import CoreDevice
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
struct PanelSpec {
    var turn: Int, scale: Double
}

private var panelSpecs: [UInt32: PanelSpec] = [:]

// loadPanelSpecs reads the displays from the device type's
// capabilities.plist, keyed by screenID. Call it before watchLitDisplay. A
// device type without the list has nothing turned.
func loadPanelSpecs(device: NSObject) {
    guard let type = device.value(forKey: "deviceType") as? NSObject,
          let bundle = (type.value(forKey: "bundlePath") as? String) ?? (type.value(forKey: "bundle") as? Bundle)?.bundlePath,
          let plist = NSDictionary(contentsOfFile: bundle + "/Contents/Resources/capabilities.plist"),
          let displays = (plist["capabilities"] as? [String: Any])?["displays"] as? [[String: Any]]
    else { return }
    for d in displays {
        guard let id = (d["screenID"] as? NSNumber)?.uint32Value else { continue }
        let rot = (d["nativeRotation"] as? NSNumber)?.intValue ?? 0
        panelSpecs[id] = PanelSpec(turn: (360 - rot % 360) % 360, scale: (d["scale"] as? NSNumber)?.doubleValue ?? 0)
    }
}

func panelSpec(_ id: UInt32) -> PanelSpec? { panelSpecs[id] }

// turned is the size of a w x h picture after a clockwise turn of t degrees.
func turned(_ w: Int, _ h: Int, _ t: Int) -> (Int, Int) {
    t == 90 || t == 270 ? (h, w) : (w, h)
}

// panelNorm maps a point normalised to the upright screen to the same point
// normalised to the framebuffer, which is what the digitizer takes.
func panelNorm(_ x: Double, _ y: Double, _ t: Int) -> (Double, Double) {
    switch t {
    case 90: (y, 1 - x)
    case 180: (1 - x, 1 - y)
    case 270: (1 - y, x)
    default: (x, y)
    }
}


private let activeLock = NSLock()
private var active: LitDisplay?

// litDisplay is the lit panel, or nil when CoreDevice has not answered or
// no single panel is lit.
func litDisplay() -> LitDisplay? {
    activeLock.lock(); defer { activeLock.unlock() }
    return active
}

// litSize is the native size of the lit panel.
func litSize() -> (Int, Int)? {
    litDisplay().map { ($0.width, $0.height) }
}

private func setLit(_ lit: LitDisplay?) {
    activeLock.lock(); defer { activeLock.unlock() }
    active = lit
}

// watchLitDisplay polls CoreDevice for the lit panel every half second, and
// logs each change. It waits up to a second for the first answer, so a folded
// Duo does not open on the black inner panel and then switch. Without
// CoreDevice it does nothing and the largest surface is streamed, as before.
func watchLitDisplay(udid: String) {
    guard HubHID.available, let want = UUID(uuidString: udid) else { return }
    let first = DispatchSemaphore(value: 0)
    Task.detached {
        guard let dev = await coreDevice(want) else {
            log("displays: CoreDevice does not list \(udid)")
            first.signal()
            return
        }
        var last: LitDisplay?
        var answered = false
        while true {
            var lit: LitDisplay?
            if let info = try? await dev.displayInfo {
                let on = info.displays.filter {
                    !$0.external && $0.active == true && $0.backlightState.rawValue.hasPrefix("active")
                }
                if on.count == 1 {
                    let id = on[0].displayId
                    lit = LitDisplay(width: Int(on[0].nativeSize.width), height: Int(on[0].nativeSize.height),
                                     id: id, turn: panelSpec(id)?.turn ?? 0)
                }
            }
            setLit(lit)
            if !answered { answered = true; first.signal() }
            if lit != last {
                log("displays: lit \(lit.map { "\($0.width)x\($0.height) id \($0.id) turn \($0.turn)" } ?? "unknown")")
                last = lit
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }
    _ = first.wait(timeout: .now() + 1)
}
