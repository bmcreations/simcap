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

private let activeLock = NSLock()
private var activeSize: (Int, Int)?

// litSize is the native size of the lit panel, or nil when CoreDevice has
// not answered or no single panel is lit.
func litSize() -> (Int, Int)? {
    activeLock.lock(); defer { activeLock.unlock() }
    return activeSize
}

private func setLit(_ lit: (Int, Int)?) {
    activeLock.lock(); defer { activeLock.unlock() }
    activeSize = lit
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
        var last: (Int, Int)?
        var answered = false
        while true {
            var lit: (Int, Int)?
            if let info = try? await dev.displayInfo {
                let on = info.displays.filter {
                    !$0.external && $0.active == true && $0.backlightState.rawValue.hasPrefix("active")
                }
                if on.count == 1 {
                    lit = (Int(on[0].nativeSize.width), Int(on[0].nativeSize.height))
                }
            }
            setLit(lit)
            if !answered { answered = true; first.signal() }
            if lit?.0 != last?.0 || lit?.1 != last?.1 {
                log("displays: lit \(lit.map { "\($0.0)x\($0.1)" } ?? "unknown")")
                last = lit
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }
    _ = first.wait(timeout: .now() + 1)
}
