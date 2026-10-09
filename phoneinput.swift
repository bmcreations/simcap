// `simcap <identifier> -phone-input` drives a physical iPhone's input through
// CoreDevice HID, the capabilities `simcap -devices` found open on a phone
// over a cable and over Wi-Fi alike. The identifier is CoreDevice's own, a
// UUID, not the hardware UDID.
//
// It speaks the same line protocol as -input (input.swift), in screen
// pixels, so the server's simInput drives either: touch, touch2, tap,
// swipe, button, key, keydown, keyup, size and route. Each line gets one
// reply, `ok` or `err <why>`. Nothing here needs CoreSimulator, so it is
// dispatched before that is loaded.

import CoreDevice
import Foundation

// phoneScreen is the size in pixels of the phone's own display: the one
// that is not external and has a size. A phone also lists external
// displays, some with a size and some without.
private func phoneScreen(_ want: UUID) -> Result<(Int, Int), InputError> {
    var result: Result<(Int, Int), InputError> = .failure(InputError("CoreDevice: no display info in 10s"))
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        defer { done.signal() }
        guard let dev = await coreDevice(want) else {
            result = .failure(InputError("CoreDevice does not list \(want)"))
            return
        }
        do {
            let info = try await dev.displayInfo
            guard let d = info.displays.first(where: { !$0.external && $0.nativeSize.width > 0 && $0.nativeSize.height > 0 }) else {
                result = .failure(InputError("the phone reports no internal display"))
                return
            }
            result = .success((Int(d.nativeSize.width), Int(d.nativeSize.height)))
        } catch {
            result = .failure(InputError("CoreDevice display info: \(error)"))
        }
    }
    _ = done.wait(timeout: .now() + 10)
    return result
}

func runPhoneInput(identifier: String) -> Never {
    guard let want = UUID(uuidString: identifier) else {
        fail("-phone-input takes CoreDevice's identifier, a UUID, not \(identifier)")
    }
    var hub: Result<HubHID, InputError>?
    var screen: (Int, Int)?

    // Both are opened on first use and a failure is retried on the next
    // command: a phone that has just been plugged in may not be listed yet.
    func hid() throws -> HubHID {
        if hub == nil { hub = HubHID.open(udid: identifier) }
        switch hub! {
        case .success(let h): return h
        case .failure(let e):
            hub = nil
            throw e
        }
    }
    func size() throws -> (Int, Int) {
        if let screen { return screen }
        let s = try phoneScreen(want).get()
        screen = s
        return s
    }
    func norm(_ x: Double, _ y: Double) throws -> (Double, Double) {
        let (w, h) = try size()
        return (min(max(x / Double(w), 0), 1), min(max(y / Double(h), 0), 1))
    }
    func phase(_ s: Substring) throws -> TouchPhase {
        switch s {
        case "down": return .down
        case "move": return .move
        case "up": return .up
        default: throw InputError("touch phase \(s)")
        }
    }

    func handle(_ f: [Substring]) throws -> String {
        func num(_ i: Int) throws -> Double {
            guard i < f.count, let v = Double(f[i]) else { throw InputError("\(f[0]): argument \(i) is not a number") }
            return v
        }
        switch f[0] {
        case "route":
            // The only route a phone has. Answered before anything opens,
            // as the server asks it of every new process.
            return "ok hub"
        case "size":
            let (w, h) = try size()
            return "ok \(w) \(h)"
        case "touch":
            guard f.count == 4 else { throw InputError("touch down|move|up X Y") }
            let (x, y) = try norm(try num(2), try num(3))
            try hid().touch(try phase(f[1]), x, y)
        case "touch2":
            guard f.count == 6 else { throw InputError("touch2 down|move|up X0 Y0 X1 Y1") }
            let (x0, y0) = try norm(try num(2), try num(3))
            let (x1, y1) = try norm(try num(4), try num(5))
            try hid().touch2(try phase(f[1]), x0, y0, x1, y1)
        case "tap":
            let h = try hid()
            let (x, y) = try norm(try num(1), try num(2))
            try h.touch(.down, x, y)
            usleep(60_000)
            try h.touch(.up, x, y)
        case "swipe":
            let h = try hid()
            let (x0, y0) = try norm(try num(1), try num(2))
            let (x1, y1) = try norm(try num(3), try num(4))
            let ms = max(try num(5), 16)
            let steps = max(Int(ms / 16), 1)
            try h.touch(.down, x0, y0)
            for i in 1...steps {
                usleep(useconds_t(ms * 1000 / Double(steps)))
                let t = Double(i) / Double(steps)
                try h.touch(.move, x0 + (x1 - x0) * t, y0 + (y1 - y0) * t)
            }
            try h.touch(.up, x1, y1)
        case "button":
            guard f.count == 2 else { throw InputError("button NAME") }
            let h = try hid()
            switch f[1] {
            case "home": try h.press(consumer: 0x40)
            case "lock": try h.press(consumer: 0x30)
            case "appSwitcher":
                try h.press(consumer: 0x40)
                usleep(150_000)
                try h.press(consumer: 0x40)
            default: throw InputError("unknown button \(f[1])")
            }
        case "key":
            let h = try hid()
            let u = UInt32(try num(1))
            let shift = f.count > 2 && f[2] == "shift"
            if shift { try h.key(leftShift, down: true) }
            try h.key(u, down: true)
            usleep(30_000)
            try h.key(u, down: false)
            if shift { try h.key(leftShift, down: false) }
        case "keydown", "keyup":
            try hid().key(UInt32(try num(1)), down: f[0] == "keydown")
        default:
            throw InputError("unknown command \(f[0])")
        }
        return "ok"
    }

    // HubHID.open blocks the calling thread and must not be on the main
    // one, so the loop runs on its own; CoreDevice's sends are XPC and need
    // no main thread.
    Thread.detachNewThread {
        while let line = readLine() {
            let f = line.split(separator: " ")
            guard !f.isEmpty else { continue }
            var reply: String
            do { reply = try handle(f) } catch { reply = "err \(error)" }
            print(reply)
            fflush(stdout)
        }
        exit(0)
    }
    dispatchMain()
}
