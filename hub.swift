// Buttons and keys through CoreDevice, the path Device Hub itself uses: the
// simulator's `hid.button` and `hid.keyboard` capabilities, served by dtuhidd
// inside it. Unlike the legacy client in input.swift, this reaches backboardd
// while Device Hub holds the simulator, so nothing has to be restarted to take
// buttons back.
//
// Measured on loupe-probe (iPhone 17, iOS 27.0, Xcode 27.0) with dtuhidd
// running, the hold flag set and backboardd restarted onto it: Home through
// the legacy client left Settings open, and the same press here reached the
// Home Screen, three times of three. Lock and typing into Spotlight worked the
// same way. On a simulator Device Hub had never touched, with dtuhidd stopped,
// the first press started dtuhidd and set the hold flag -- so once a button
// has gone this way, every later one must too, which is why simcap sends all
// buttons and keys here whenever this opens.
//
// CoreDevice ships no Swift interface. coredevice/CoreDevice.swift declares
// the few symbols used, matched to the mangled names Xcode 27 exports, and
// the framework is weak-linked, so a simcap built against it still streams
// video when an Xcode update moves it; `open` then returns nil and input.swift
// falls back to the legacy client.

import CoreDevice
import Foundation

private let coreDevicePath = "/Library/Developer/PrivateFrameworks/CoreDevice.framework/CoreDevice"

// Generic and unoptimised, so A.ProtocolType is read from the real
// conformance at run time rather than from the stub's placeholder alias.
@inline(never) @_optimize(none)
private func implementation<A: DeviceCapability>(_ d: RemoteDevice, _ m: CapabilityStaticMember<A>) async throws -> Any {
    let impl: A.ProtocolType = try await d.getImplementation(for: m)
    return impl as Any
}

final class HubHID {
    let button: any HIDButton
    let keyboard: any HIDKeyboard
    let digitizer: any HIDDigitizer

    private init(button: any HIDButton, keyboard: any HIDKeyboard, digitizer: any HIDDigitizer) {
        self.button = button
        self.keyboard = keyboard
        self.digitizer = digitizer
    }

    static var available: Bool { dlopen(coreDevicePath, RTLD_LAZY) != nil }

    // open blocks the calling thread, which must not be the main thread,
    // for up to five seconds. Device discovery took 46ms here.
    static func open(udid: String) -> Result<HubHID, InputError> {
        guard available else { return .failure(InputError("CoreDevice is not installed")) }
        guard let want = UUID(uuidString: udid) else { return .failure(InputError("bad udid")) }
        var result: Result<HubHID, InputError> = .failure(InputError("CoreDevice: no answer in 5s"))
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            defer { done.signal() }
            let mgr = DeviceManager(serviceConnection: CoreDeviceService.sharedConnection,
                                    allowedDeviceVisibilityClasses: [.default, .simulators])
            await mgr.waitForPostPluginLoadCheckIn()
            await mgr.awaitFullInitialization()
            guard let dev = mgr.allDevices().first(where: { $0.deviceIdentifier == want }) else {
                result = .failure(InputError("CoreDevice does not list \(udid)"))
                return
            }
            do {
                let b = try await implementation(dev, CapabilityStaticMember<HIDDeviceCapability>.button)
                let k = try await implementation(dev, CapabilityStaticMember<HIDDeviceCapability>.keyboard)
                let t = try await implementation(dev, CapabilityStaticMember<HIDDeviceCapability>.digitizer)
                guard let button = b as? any HIDButton, let keyboard = k as? any HIDKeyboard,
                      let digitizer = t as? any HIDDigitizer else {
                    result = .failure(InputError("CoreDevice capabilities are not HIDButton, HIDKeyboard and HIDDigitizer"))
                    return
                }
                result = .success(HubHID(button: button, keyboard: keyboard, digitizer: digitizer))
            } catch {
                result = .failure(InputError("CoreDevice: \(error)"))
            }
        }
        _ = done.wait(timeout: .now() + 5)
        return result
    }

    // Consumer page: 0x40 Menu is Home and 0x30 Power is lock, both run.
    func press(consumer code: Int) throws {
        try button.sendCustomButton(usagePage: 0x0C, usageCode: code, state: .down)
        usleep(80_000)
        try button.sendCustomButton(usagePage: 0x0C, usageCode: code, state: .up)
        button.sendBarrier()
    }

    func key(_ usage: UInt32, down: Bool) throws {
        try keyboard.send(key: HIDKeyboardUsageCode(rawValue: UInt16(usage)), state: down ? .down : .up)
        keyboard.sendBarrier()
    }

    // x and y are normalised to the screen, 0 to 1.
    func touch(_ phase: TouchPhase, _ x: Double, _ y: Double) throws {
        let type: DigitizerEventType = switch phase {
        case .down: .start
        case .move: .position
        case .up: .end
        }
        try digitizer.send(pointOne: DigitizerPoint(x: x, y: y), pointTwo: nil, eventType: type, edge: .none, target: .mainScreen)
        digitizer.sendBarrier()
    }
}
