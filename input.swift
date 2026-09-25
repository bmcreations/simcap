// Input mode: `simcap <udid> -input` injects touches, buttons and keys through
// SimulatorKit's Indigo HID client and captures nothing. The server runs one
// per simulator, separate from the video process, so /api/input works with no
// session open and a video relaunch never takes input down with it.
//
// stdin is one command per line, and every command gets exactly one line back
// on stdout, `ok` or `err <why>`, so the caller sees a failure instead of
// assuming its tap landed. Coordinates are framebuffer pixels, which is also
// what the video stream carries: simcap does not downscale.
//
//   touch down|move|up X Y
//   tap X Y
//   swipe X0 Y0 X1 Y1 MS
//   button home|lock|appSwitcher
//   key USAGE [shift]          press and release one HID keyboard usage
//   keydown USAGE | keyup USAGE
//   size                       -> ok W H
//   ui                         -> ok {json}, the accessibility tree (ax.swift)
//
// Measured on an iPhone 17 simulator, iOS 27.0, Xcode 27.0: every message
// completed in 1-3ms. The builders are private and moved in iOS 26 -- the
// five-argument mouse call idb and AXe use stopped working there -- so each
// signature below is the one that was run, not one inferred from a header.

import CoreGraphics
import Foundation
import ObjectiveC

private let anyImage = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT

private func sym<T>(_ name: String, _: T.Type) -> T {
    guard let p = dlsym(anyImage, name) else { fail("SimulatorKit has no \(name)") }
    return unsafeBitCast(p, to: T.self)
}

// The phone's digitizer and its button target. A message aimed at a target
// nothing registered takes backboardd down.
private let touchTarget: UInt32 = 0x32
private let buttonTarget: UInt32 = 0x33

private typealias MouseFn = @convention(c) (UnsafePointer<CGPoint>, UnsafePointer<CGPoint>?, UInt32, UInt32, UInt32,
                                            Double, Double, Double, Double) -> UnsafeMutableRawPointer?
private typealias ButtonFn = @convention(c) (UInt32, UInt32, UInt32) -> UnsafeMutableRawPointer?
private typealias ArbitraryFn = @convention(c) (UInt32, UInt32, UInt32, UInt32) -> UnsafeMutableRawPointer?

private final class HID {
    let client: AnyObject
    let cls: AnyClass
    let sendSel = NSSelectorFromString("sendWithMessage:freeWhenDone:completionQueue:completion:")
    let completions = DispatchQueue(label: "simcap.hid.completions")
    let mouse = sym("IndigoHIDMessageForMouseNSEvent", MouseFn.self)
    let button = sym("IndigoHIDMessageForButton", ButtonFn.self)
    let arbitrary = sym("IndigoHIDMessageForHIDArbitrary", ArbitraryFn.self)

    init(device: NSObject) {
        guard let cls = NSClassFromString("_TtC12SimulatorKit24SimDeviceLegacyHIDClient") else {
            fail("SimulatorKit has no SimDeviceLegacyHIDClient")
        }
        self.cls = cls
        typealias AllocFn = @convention(c) (AnyClass, Selector) -> Unmanaged<AnyObject>?
        typealias InitFn = @convention(c) (AnyObject, Selector, AnyObject, AutoreleasingUnsafeMutablePointer<NSError?>) -> Unmanaged<AnyObject>?
        let allocSel = NSSelectorFromString("alloc"), initSel = NSSelectorFromString("initWithDevice:error:")
        // init consumes its receiver, so alloc's +1 goes straight to it.
        // Taking it as retained here would release it a second time when this
        // scope ends, and the client would be freed before its first send.
        let raw = unsafeBitCast(class_getMethodImplementation(object_getClass(cls), allocSel)!, to: AllocFn.self)(cls, allocSel)!
            .takeUnretainedValue()
        var err: NSError?
        guard let client = withUnsafeMutablePointer(to: &err, {
            unsafeBitCast(class_getMethodImplementation(cls, initSel)!, to: InitFn.self)(raw, initSel, device, AutoreleasingUnsafeMutablePointer($0))?
                .takeRetainedValue()
        }) else { fail("HID client: \(err?.localizedDescription ?? "init returned nil")") }
        self.client = client
    }

    // send hands the message over, freeing it when done, and waits for the
    // completion so a reply of `ok` means the simulator took it.
    func send(_ msg: UnsafeMutableRawPointer?) throws {
        guard let msg else { throw InputError("message builder returned nil") }
        typealias Fn = @convention(c) (AnyObject, Selector, UnsafeMutableRawPointer, ObjCBool, AnyObject?, AnyObject?) -> Void
        let done = DispatchSemaphore(value: 0)
        var sendErr: Error?
        let completion: @convention(block) (NSError?) -> Void = { e in sendErr = e; done.signal() }
        unsafeBitCast(class_getMethodImplementation(cls, sendSel)!, to: Fn.self)(client, sendSel, msg, true, completions, completion as AnyObject)
        if done.wait(timeout: .now() + 2) == .timedOut { throw InputError("no completion in 2s") }
        if let sendErr { throw InputError("send: \(sendErr.localizedDescription)") }
    }



    // The nine-argument mouse call, with the point normalised to the screen.
    // Of the two recipes tried it missed nothing in 10 open-and-close taps,
    // where the IOHIDEvent digitizer wrapper missed 3 of 16.
    func touch(_ phase: TouchPhase, _ nx: Double, _ ny: Double, _ w: Double, _ h: Double) throws {
        var p = CGPoint(x: nx, y: ny)
        let (event, direction): (UInt32, UInt32) = switch phase {
        case .down: (1, 1)
        case .up: (2, 2)
        case .move: (6, 0)
        }
        try send(withUnsafePointer(to: &p) { mouse($0, nil, touchTarget, event, direction, 1, 1, w, h) })
    }

    // Home is 0 and lock is 1; direction 1 is down and 2 is up.
    func press(_ code: UInt32) throws {
        try send(button(code, 1, buttonTarget))
        usleep(100_000)
        try send(button(code, 2, buttonTarget))
    }

    // Page 7 is the HID keyboard page; operation 1 is down and 2 is up.
    func key(_ usage: UInt32, down: Bool) throws {
        try send(arbitrary(touchTarget, 7, usage, down ? 1 : 2))
    }
}

enum TouchPhase { case down, move, up }

struct InputError: Error, CustomStringConvertible {
    let description: String
    init(_ s: String) { description = s }
}

private let leftShift: UInt32 = 225

func runInput(device: NSObject, udid: String, size: @escaping () -> (Int, Int)) -> Never {
    // Everything that builds a message runs on the main thread: the mouse
    // builder reads AppKit's per-thread state, and off the main thread the
    // simulator drops what it builds without a word.
    let hid = HID(device: device)
    log("input ready")

    func norm(_ x: Double, _ y: Double) throws -> (Double, Double, Double, Double) {
        let (w, h) = size()
        guard w > 0, h > 0 else { throw InputError("no framebuffer") }
        return (min(max(x / Double(w), 0), 1), min(max(y / Double(h), 0), 1), Double(w), Double(h))
    }

    // Touch, tap and swipe, the same through either client.
    func gesture(_ f: [Substring], _ touch: (TouchPhase, Double, Double, Double, Double) throws -> Void) throws -> Bool {
        func num(_ i: Int) throws -> Double {
            guard i < f.count, let v = Double(f[i]) else { throw InputError("\(f[0]): argument \(i) is not a number") }
            return v
        }
        switch f[0] {
        case "touch":
            guard f.count == 4 else { throw InputError("touch down|move|up X Y") }
            let phase: TouchPhase
            switch f[1] {
            case "down": phase = .down
            case "move": phase = .move
            case "up": phase = .up
            default: throw InputError("touch phase \(f[1])")
            }
            let (x, y, w, h) = try norm(try num(2), try num(3))
            try touch(phase, x, y, w, h)
        case "tap":
            let (x, y, w, h) = try norm(try num(1), try num(2))
            try touch(.down, x, y, w, h)
            usleep(60_000)
            try touch(.up, x, y, w, h)
        case "swipe":
            let (x0, y0, w, h) = try norm(try num(1), try num(2))
            let (x1, y1, _, _) = try norm(try num(3), try num(4))
            let ms = max(try num(5), 16)
            let steps = max(Int(ms / 16), 1)
            try touch(.down, x0, y0, w, h)
            for i in 1...steps {
                usleep(useconds_t(ms * 1000 / Double(steps)))
                let t = Double(i) / Double(steps)
                try touch(.move, x0 + (x1 - x0) * t, y0 + (y1 - y0) * t, w, h)
            }
            try touch(.up, x1, y1, w, h)
        default:
            return false
        }
        return true
    }

    func handle(_ f: [Substring]) throws -> String {
        func num(_ i: Int) throws -> Double {
            guard i < f.count, let v = Double(f[i]) else { throw InputError("\(f[0]): argument \(i) is not a number") }
            return v
        }
        if try gesture(f, hid.touch) { return "ok" }
        switch f[0] {
        case "size":
            let (w, h) = size()
            return "ok \(w) \(h)"
        case "button":
            guard f.count == 2 else { throw InputError("button NAME") }
            switch f[1] {
            case "home": try hid.press(0)
            case "lock": try hid.press(1)
            // Two Home presses 150ms apart, as a finger does it. The switcher
            // was shown on the first try this way.
            case "appSwitcher":
                try hid.press(0)
                usleep(150_000)
                try hid.press(0)
            default: throw InputError("unknown button \(f[1])")
            }
        case "key":
            let usage = UInt32(try num(1))
            let shift = f.count > 2 && f[2] == "shift"
            if shift { try hid.key(leftShift, down: true) }
            try hid.key(usage, down: true)
            usleep(30_000)
            try hid.key(usage, down: false)
            if shift { try hid.key(leftShift, down: false) }
        case "keydown", "keyup":
            try hid.key(UInt32(try num(1)), down: f[0] == "keydown")
        default:
            throw InputError("unknown command \(f[0])")
        }
        return "ok"
    }

    var tree: AXTree?
    func ui() throws -> String {
        if tree == nil { tree = try AXTree(device: device) }
        let data = try JSONSerialization.data(withJSONObject: try tree!.dump(), options: [.sortedKeys])
        return "ok " + String(decoding: data, as: UTF8.self)
    }

    func front() throws -> String {
        if tree == nil { tree = try AXTree(device: device) }
        return "ok \(try tree!.frontPid())"
    }

    // Buttons and keys go through CoreDevice when it opens, and through the
    // legacy client otherwise; see hub.swift for why it is all or nothing.
    // It is opened on the first button or key, on this reader thread,
    // because opening blocks and the main thread sends touches.
    var hub: Result<HubHID, InputError>?
    func route() -> HubHID? {
        if hub == nil {
            hub = HubHID.open(udid: udid)
            switch hub! {
            case .success: log("buttons and keys through CoreDevice")
            case .failure(let e): log("buttons and keys through the legacy client: \(e)")
            }
        }
        if case .success(let h) = hub! { return h }
        return nil
    }

    // hubHandle sends one button or key through CoreDevice. Its sends are
    // XPC and need no main thread; the probe that proved them ran on a task.
    func hubHandle(_ h: HubHID, _ f: [Substring]) throws {
        func usage(_ i: Int) throws -> UInt32 {
            guard i < f.count, let v = UInt32(f[i]) else { throw InputError("\(f[0]): argument \(i) is not a number") }
            return v
        }
        if try gesture(f, { p, x, y, _, _ in try h.touch(p, x, y) }) { return }
        switch f[0] {
        case "button":
            guard f.count == 2 else { throw InputError("button NAME") }
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
            let u = try usage(1)
            let shift = f.count > 2 && f[2] == "shift"
            if shift { try h.key(leftShift, down: true) }
            try h.key(u, down: true)
            usleep(30_000)
            try h.key(u, down: false)
            if shift { try h.key(leftShift, down: false) }
        default: // keydown, keyup
            try h.key(try usage(1), down: f[0] == "keydown")
        }
    }

    Thread.detachNewThread {
        while let line = readLine() {
            let f = line.split(separator: " ")
            guard !f.isEmpty else { continue }
            var reply = ""
            if f[0] == "route" {
                if route() != nil {
                    reply = "ok hub"
                } else if case .failure(let e) = hub! {
                    reply = "ok legacy \(e)"
                }
                print(reply)
                fflush(stdout)
                continue
            }
            if ["button", "key", "keydown", "keyup", "touch", "tap", "swipe"].contains(f[0]), let h = route() {
                do { try hubHandle(h, f); reply = "ok" } catch { reply = "err \(error)" }
                print(reply)
                fflush(stdout)
                continue
            }
            // Not on the main thread: the translator blocks on each request
            // it makes, and nothing says it never needs the main thread to
            // finish one.
            if f[0] == "ui" || f[0] == "front" {
                do { reply = try f[0] == "ui" ? ui() : front() } catch { reply = "err \(error)" }
                print(reply)
                fflush(stdout)
                continue
            }
            DispatchQueue.main.sync {
                do { reply = try handle(f) } catch { reply = "err \(error)" }
            }
            print(reply)
            fflush(stdout)
        }
        exit(0)
    }
    dispatchMain()
}
