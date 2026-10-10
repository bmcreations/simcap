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
//
// A command fails in one of two phases, and the reply says which, because the
// server retries only a command that sent nothing:
//
//   err unreachable: <text>  Nothing left the Mac. The open failed, the
//       display size could not be read, or the capability did not answer a
//       check made BEFORE the first send (CoreDevice's own text, such as error
//       1001 "not supported by this device"). The server wakes the tunnel with
//       devicectl and sends the command once more.
//   err undelivered: <text>  A send went out, or may have, and then something
//       failed: a send threw, a touch's up could not be delivered, or the
//       capability stopped answering after the send. Whether the phone got it
//       is unknown, so the server never resends: that would tap twice, press
//       Home twice or double a typed character.
//   err <text>               Anything else, such as a bad argument.
//
// Every wait here is shorter than the server's budget for a command
// (phoneInputBudget in iosdeviceinput.go, 15s), so CoreDevice's error reaches
// the caller instead of the server timing out first and killing this process
// mid-open. The worst cold command is the sum of the waits: HubHID.open 5s,
// phoneScreen 4s, the pre-send check 2s and the post-send check 2s, 13s. The
// viewer's touch and touch2, keydown and keyup are never checked.

import CoreDevice
import Foundation

// phoneScreen is the size in pixels of the phone's own display: the one
// that is not external and has a size. A phone also lists external
// displays, some with a size and some without.
private func phoneScreen(_ want: UUID) -> Result<(Int, Int), InputError> {
    var result: Result<(Int, Int), InputError> = .failure(InputError("CoreDevice: no display info in 4s"))
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
    _ = done.wait(timeout: .now() + 4)
    return result
}

// Unreachable is a failure before anything was sent: nothing reached the
// phone, so the server may wake the tunnel and send the command again.
private struct Unreachable: Error, CustomStringConvertible {
    let description: String
}

// Undelivered is a failure at or after a send. The phone may have received
// the command, so it must not be sent again.
private struct Undelivered: Error, CustomStringConvertible {
    let description: String
}

// How long a capability check may take, before a send and after one.
private let checkSeconds = 2.0

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
            throw Unreachable(description: e.description)
        }
    }
    // pre runs everything that comes before a command's first send: opening
    // the capabilities, reading the screen size, checking the capability. Any
    // failure is Unreachable, because nothing was sent, and drops the cached
    // capabilities so the next command opens fresh ones.
    func pre<T>(_ body: () throws -> T) throws -> T {
        do { return try body() } catch {
            hub = nil
            if error is Unreachable { throw error }
            throw Unreachable(description: "\(error)")
        }
    }
    // send runs every send of a command and what follows it. Any failure is
    // Undelivered, whatever its text: a throw on the very first down and a
    // 1001 look the same as one halfway through, since a send may have gone
    // out. It never goes through a classifier that could call it unreachable.
    func send<T>(_ body: () throws -> T) throws -> T {
        do { return try body() } catch {
            hub = nil
            if error is Undelivered { throw error }
            throw Undelivered(description: "\(error)")
        }
    }
    func size() throws -> (Int, Int) {
        if let screen { return screen }
        let s: (Int, Int)
        do { s = try phoneScreen(want).get() } catch { throw Unreachable(description: "\(error)") }
        screen = s
        return s
    }
    // lift lifts a finger, once more if the first try fails, so a tap whose
    // down went through does not leave the finger down. If both fail the
    // phone may still have it down, and the error says so.
    func lift(_ h: HubHID, _ x: Double, _ y: Double) throws {
        do { try h.touch(.up, x, y) } catch {
            usleep(100_000)
            do { try h.touch(.up, x, y) } catch {
                throw Undelivered(description: "\(error); the touch's up was not delivered, so a finger may be down on the phone")
            }
        }
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
            let (px, py) = (try num(2), try num(3))
            let ph = try phase(f[1])
            // The viewer's live touch: no capability check, so a down cannot
            // hold up the message loop behind it.
            let (x, y) = try pre { try norm(px, py) }
            let h = try pre { try hid() }
            try send { try h.touch(ph, x, y) }
        case "touch2":
            guard f.count == 6 else { throw InputError("touch2 down|move|up X0 Y0 X1 Y1") }
            let (px0, py0, px1, py1) = (try num(2), try num(3), try num(4), try num(5))
            let ph = try phase(f[1])
            let (x0, y0, x1, y1) = try pre { () -> (Double, Double, Double, Double) in
                let a = try norm(px0, py0), b = try norm(px1, py1)
                return (a.0, a.1, b.0, b.1)
            }
            let h = try pre { try hid() }
            try send { try h.touch2(ph, x0, y0, x1, y1) }
        case "tap":
            let (px, py) = (try num(1), try num(2))
            let (x, y) = try pre { try norm(px, py) }
            let h = try pre { () -> HubHID in
                let h = try hid()
                try h.validate(.digitizer, within: checkSeconds)
                return h
            }
            try send {
                try h.touch(.down, x, y)
                usleep(60_000)
                try lift(h, x, y)
                try h.validate(.digitizer, within: checkSeconds)
            }
        case "swipe":
            let (p0x, p0y, p1x, p1y) = (try num(1), try num(2), try num(3), try num(4))
            let ms = max(try num(5), 16)
            let steps = max(Int(ms / 16), 1)
            let (x0, y0, x1, y1) = try pre { () -> (Double, Double, Double, Double) in
                let a = try norm(p0x, p0y), b = try norm(p1x, p1y)
                return (a.0, a.1, b.0, b.1)
            }
            let h = try pre { () -> HubHID in
                let h = try hid()
                try h.validate(.digitizer, within: checkSeconds)
                return h
            }
            try send {
                try h.touch(.down, x0, y0)
                var lastX = x0, lastY = y0
                do {
                    for i in 1...steps {
                        usleep(useconds_t(ms * 1000 / Double(steps)))
                        let t = Double(i) / Double(steps)
                        lastX = x0 + (x1 - x0) * t
                        lastY = y0 + (y1 - y0) * t
                        try h.touch(.move, lastX, lastY)
                    }
                } catch {
                    // The down went through; try to lift before reporting.
                    try lift(h, lastX, lastY)
                    throw error
                }
                try lift(h, x1, y1)
                try h.validate(.digitizer, within: checkSeconds)
            }
        case "button":
            guard f.count == 2 else { throw InputError("button NAME") }
            let name = String(f[1])
            guard ["home", "lock", "appSwitcher"].contains(name) else { throw InputError("unknown button \(name)") }
            let h = try pre { () -> HubHID in
                let h = try hid()
                try h.validate(.button, within: checkSeconds)
                return h
            }
            try send {
                switch name {
                case "home": try h.press(consumer: 0x40)
                case "lock": try h.press(consumer: 0x30)
                default:
                    try h.press(consumer: 0x40)
                    usleep(150_000)
                    try h.press(consumer: 0x40)
                }
                try h.validate(.button, within: checkSeconds)
            }
        case "key":
            let u = UInt32(try num(1))
            let shift = f.count > 2 && f[2] == "shift"
            let h = try pre { () -> HubHID in
                let h = try hid()
                try h.validate(.keyboard, within: checkSeconds)
                return h
            }
            try send {
                if shift { try h.key(leftShift, down: true) }
                try h.key(u, down: true)
                usleep(30_000)
                try h.key(u, down: false)
                if shift { try h.key(leftShift, down: false) }
                try h.validate(.keyboard, within: checkSeconds)
            }
        case "keydown", "keyup":
            let u = UInt32(try num(1))
            let h = try pre { try hid() }
            try send { try h.key(u, down: f[0] == "keydown") }
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
            do { reply = try handle(f) } catch {
                if error is Unreachable {
                    reply = "err unreachable: \(error)"
                } else if error is Undelivered {
                    reply = "err undelivered: \(error)"
                } else {
                    reply = "err \(error)"
                }
            }
            writeReply(reply)
        }
        exit(0)
    }
    dispatchMain()
}
