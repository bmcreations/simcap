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
import IOKit

private let coreDevicePath = "/Library/Developer/PrivateFrameworks/CoreDevice.framework/CoreDevice"

// Generic and unoptimised, so A.ProtocolType is read from the real
// conformance at run time rather than from the stub's placeholder alias.
@inline(never) @_optimize(none)
func implementation<A: DeviceCapability>(_ d: RemoteDevice, _ m: CapabilityStaticMember<A>) async throws -> Any {
    let impl: A.ProtocolType = try await d.getImplementation(for: m)
    return impl as Any
}

// coreDevice finds the simulator among the devices CoreDevice lists.
// DeviceManager.shared lists only physical devices, so this builds its own
// manager with simulators allowed.
func coreDevice(_ want: UUID) async -> RemoteDevice? {
    let mgr = DeviceManager(serviceConnection: CoreDeviceService.sharedConnection,
                            allowedDeviceVisibilityClasses: [.default, .simulators])
    await mgr.waitForPostPluginLoadCheckIn()
    await mgr.awaitFullInitialization()
    return mgr.allDevices().first(where: { $0.deviceIdentifier == want })
}

final class HubHID {
    // Optional: a wired iPhone was seen to refuse `hid.button` while its
    // digitizer answered, and taps should not fail over a button.
    let button: (any HIDButton)?
    let keyboard: (any HIDKeyboard)?
    let digitizer: any HIDDigitizer
    // Optional: only the hinge uses it, and a device without one should
    // not lose its buttons over it.
    let vendor: (any HIDVendorDefined)?
    // Kept so a capability can be asked for again after a send; see validate.
    let device: RemoteDevice

    private init(device: RemoteDevice, button: (any HIDButton)?, keyboard: (any HIDKeyboard)?, digitizer: any HIDDigitizer, vendor: (any HIDVendorDefined)?) {
        self.device = device
        self.button = button
        self.keyboard = keyboard
        self.digitizer = digitizer
        self.vendor = vendor
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
            guard let dev = await coreDevice(want) else {
                result = .failure(InputError("CoreDevice does not list \(udid)"))
                return
            }
            do {
                let t = try await implementation(dev, CapabilityStaticMember<HIDDeviceCapability>.digitizer)
                guard let digitizer = t as? any HIDDigitizer else {
                    result = .failure(InputError("CoreDevice capability is not HIDDigitizer"))
                    return
                }
                let b = try? await implementation(dev, CapabilityStaticMember<HIDDeviceCapability>.button)
                let k = try? await implementation(dev, CapabilityStaticMember<HIDDeviceCapability>.keyboard)
                let v = try? await implementation(dev, CapabilityStaticMember<HIDDeviceCapability>.vendorDefined)
                result = .success(HubHID(device: dev, button: b as? any HIDButton, keyboard: k as? any HIDKeyboard, digitizer: digitizer,
                                         vendor: v as? any HIDVendorDefined))
            } catch {
                result = .failure(InputError("CoreDevice: \(error)"))
            }
        }
        _ = done.wait(timeout: .now() + 5)
        return result
    }

    enum Kind { case button, keyboard, digitizer }

    // validate asks CoreDevice for the capability again and throws if it
    // cannot be had. CoreDevice gives no delivery signal: sendBarrier() is
    // `() -> ()` on all three HID protocols, with no throw and no completion,
    // and a send on a capability whose tunnel has dropped was seen to return
    // without throwing. So this is the only evidence available after a send,
    // and `ok` after it means "sent, and the capability still answered", not
    // "the phone received it". A report dropped while the capability still
    // answers is not caught. Blocks the calling thread for up to `seconds`.
    func validate(_ kind: Kind, within seconds: Double = 3) throws {
        var failure: InputError? = InputError("CoreDevice: capability did not answer in \(Int(seconds))s")
        let done = DispatchSemaphore(value: 0)
        let dev = device
        Task.detached {
            defer { done.signal() }
            do {
                switch kind {
                case .button: _ = try await implementation(dev, CapabilityStaticMember<HIDDeviceCapability>.button)
                case .keyboard: _ = try await implementation(dev, CapabilityStaticMember<HIDDeviceCapability>.keyboard)
                case .digitizer: _ = try await implementation(dev, CapabilityStaticMember<HIDDeviceCapability>.digitizer)
                }
                failure = nil
            } catch {
                failure = InputError("CoreDevice: \(error)")
            }
        }
        _ = done.wait(timeout: .now() + seconds)
        if let failure { throw failure }
    }

    // Consumer page: 0x40 Menu is Home and 0x30 Power is lock, both run.
    func press(consumer code: Int) throws {
        guard let button else { throw InputError("CoreDevice: this device has no hid.button") }
        try button.sendCustomButton(usagePage: 0x0C, usageCode: code, state: .down)
        usleep(80_000)
        try button.sendCustomButton(usagePage: 0x0C, usageCode: code, state: .up)
        button.sendBarrier()
    }

    func key(_ usage: UInt32, down: Bool) throws {
        guard let keyboard else { throw InputError("CoreDevice: this device has no hid.keyboard") }
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
        try digitizer.send(pointOne: DigitizerPoint(x: x, y: y), pointTwo: nil, eventType: type, edge: .none, target: digitizerTarget())
        digitizer.sendBarrier()
    }

    // Two fingers in one event, which is what pinch and two-finger rotate
    // need: the legacy mouse builder carries a single point.
    func touch2(_ phase: TouchPhase, _ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) throws {
        let type: DigitizerEventType = switch phase {
        case .down: .start
        case .move: .position
        case .up: .end
        }
        try digitizer.send(pointOne: DigitizerPoint(x: x0, y: y0), pointTwo: DigitizerPoint(x: x1, y: y1),
                           eventType: type, edge: .none, target: digitizerTarget())
        digitizer.sendBarrier()
    }
}

extension HubHID {
    func hinge(_ degrees: Double) throws {
        guard let vendor else { throw InputError("CoreDevice has no vendor-defined HID capability here") }
        try sendHinge(vendor, degrees)
    }
}

// sendHinge sets a foldable's hinge angle, 0 closed to 180 flat, the way
// Device Hub's hinge slider does: a dictionary serialised with IOCFSerialize
// in its binary form, on vendor page 0xff61 usage 0x5b, version 0. The keys
// and values are the ones its CoreDevice plugin
// (CoreDevicePopDeviceKitExtension) builds on Xcode 27.1; they were read out
// of the binary, not from a header.
func sendHinge(_ vendor: any HIDVendorDefined, _ degrees: Double) throws {
    let report: [String: Any] = [
        "provider": "com.apple.Virtualization.VirtualMachines",
        "source": "hinge-slider-control",
        "type": "range",
        "value": min(max(degrees, 0), 180),
    ]
    guard let data = IOCFSerialize(report as CFDictionary, CFOptionFlags(kIOCFSerializeToBinary)) else {
        throw InputError("IOCFSerialize failed")
    }
    try vendor.send(usagePage: 0xff61, usage: 0x5b, version: 0, data: data as Data)
    vendor.sendBarrier()
}

// openHinge opens only the vendor-defined capability, for an input process
// whose CoreDevice open failed and so runs on the legacy client. The hinge
// has no legacy equivalent, and taking this one capability leaves touch,
// buttons and keys where they are. The full open missed its five seconds
// about one time in eight while the Mac's load average read 370, and
// succeeded in 0.8s on the next try, so this waits longer and is retried on
// each hinge until it opens.
final class HubHinge {
    let vendor: any HIDVendorDefined
    init(_ vendor: any HIDVendorDefined) { self.vendor = vendor }
    func set(_ degrees: Double) throws { try sendHinge(vendor, degrees) }
}

func openHinge(udid: String) -> Result<HubHinge, InputError> {
    guard HubHID.available else { return .failure(InputError("CoreDevice is not installed")) }
    guard let want = UUID(uuidString: udid) else { return .failure(InputError("bad udid")) }
    var result: Result<HubHinge, InputError> = .failure(InputError("CoreDevice: no answer in 10s"))
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        defer { done.signal() }
        guard let dev = await coreDevice(want) else {
            result = .failure(InputError("CoreDevice does not list \(udid)"))
            return
        }
        do {
            let v = try await implementation(dev, CapabilityStaticMember<HIDDeviceCapability>.vendorDefined)
            guard let vendor = v as? any HIDVendorDefined else {
                result = .failure(InputError("CoreDevice capability is not HIDVendorDefined"))
                return
            }
            result = .success(HubHinge(vendor))
        } catch {
            result = .failure(InputError("CoreDevice: \(error)"))
        }
    }
    _ = done.wait(timeout: .now() + 10)
    return result
}

// digitizerTarget aims a touch at the lit panel. mainScreen is the outer
// panel on an iPhone Duo, so an unfolded Duo took every touch and did
// nothing with it.
func digitizerTarget() -> DigitizerTarget {
    let all: [DigitizerTarget] = [.display1, .display2, .display3, .display4, .display5,
                                  .display6, .display7, .display8, .display9, .display10]
    guard let id = litDisplay()?.id, id >= 1, Int(id) <= all.count else { return .mainScreen }
    return all[Int(id) - 1]
}
