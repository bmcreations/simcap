// Physical iPhones, as CoreDevice sees them, over a cable or the network.
// This is a probe, not a stream: it answers whether the HID capabilities
// hub.swift drives on a simulator are offered by a real device too, and
// whether that holds over Wi-Fi, before anything is built on either.
//
//   simcap -devices                 one JSON line per physical device
//   simcap -devices -press <id>     also press Home on that device
//
// Names, models and how each device is connected come from `devicectl list
// devices`, whose JSON is public; CoreDevice's own RemoteDevice properties
// would need more stub symbols, each of which has to be matched to a mangled
// name before it links. The two are joined on the CoreDevice identifier,
// which is what devicectl reports as `identifier`.
//
// Looking a capability up sends nothing to the device. Only -press does, and
// a Home press on a locked phone only wakes its screen.

import CoreDevice
import Foundation

// within runs body on its own task and waits at most seconds for it. A
// lookup against a phone that has wandered off the network may never
// return, and one such device must not hold up the rest of the listing.
private final class Box<T>: @unchecked Sendable { var value: Result<T, Error>? }

private func within<T>(_ seconds: Double, _ body: @escaping @Sendable () async throws -> T) -> Result<T, Error> {
    let box = Box<T>()
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        defer { done.signal() }
        do { box.value = .success(try await body()) } catch { box.value = .failure(error) }
    }
    if done.wait(timeout: .now() + seconds) == .timedOut {
        return .failure(InputError("no answer in \(Int(seconds))s"))
    }
    return box.value ?? .failure(InputError("no answer"))
}

private func note(_ s: String) {
    FileHandle.standardError.write("simcap: devices: \(s)\n".data(using: .utf8)!)
}

// devicectlDevices returns devicectl's device list keyed by identifier,
// physical devices only, or nothing when devicectl is missing or fails.
private func devicectlDevices() -> [String: [String: Any]] {
    let out = FileManager.default.temporaryDirectory
        .appendingPathComponent("simcap-devices-\(getpid()).json")
    defer { try? FileManager.default.removeItem(at: out) }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    p.arguments = ["devicectl", "list", "devices", "--json-output", out.path]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    let finished = DispatchSemaphore(value: 0)
    p.terminationHandler = { _ in finished.signal() }
    do { try p.run() } catch {
        note("devicectl: \(error)")
        return [:]
    }
    if finished.wait(timeout: .now() + 20) == .timedOut {
        p.terminate()
        note("devicectl: no answer in 20s")
        return [:]
    }
    guard let data = try? Data(contentsOf: out),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let list = (root["result"] as? [String: Any])?["devices"] as? [[String: Any]]
    else {
        note("devicectl: exit \(p.terminationStatus), no device list")
        return [:]
    }
    var byID: [String: [String: Any]] = [:]
    for d in list {
        guard let id = d["identifier"] as? String else { continue }
        let hw = d["hardwareProperties"] as? [String: Any] ?? [:]
        if let reality = hw["reality"] as? String, reality != "physical" { continue }
        byID[id.uppercased()] = d
    }
    return byID
}

// summary picks out of a devicectl entry what says which phone it is and
// how it is reached. transport is "wired" over a cable and "localNetwork"
// over Wi-Fi; tunnel is whether a developer tunnel is up.
private func summary(_ d: [String: Any]) -> [String: Any] {
    let dev = d["deviceProperties"] as? [String: Any] ?? [:]
    let hw = d["hardwareProperties"] as? [String: Any] ?? [:]
    let conn = d["connectionProperties"] as? [String: Any] ?? [:]
    var s: [String: Any] = [:]
    s["name"] = dev["name"]
    s["os"] = dev["osVersionNumber"]
    s["developerMode"] = dev["developerModeStatus"]
    s["model"] = hw["marketingName"] ?? hw["productType"]
    s["platform"] = hw["platform"]
    s["udid"] = hw["udid"]
    s["transport"] = conn["transportType"]
    s["pairing"] = conn["pairingState"]
    s["tunnel"] = conn["tunnelState"]
    return s
}

// probeCaps looks up each capability simcap uses on a simulator and says
// whether the device offers it: "ok", or the error.
private func probeCaps(_ dev: RemoteDevice) -> [String: String] {
    typealias Lookup = @Sendable () async throws -> Any
    let lookups: [(String, Lookup)] = [
        ("button", { try await implementation(dev, CapabilityStaticMember<HIDDeviceCapability>.button) }),
        ("keyboard", { try await implementation(dev, CapabilityStaticMember<HIDDeviceCapability>.keyboard) }),
        ("digitizer", { try await implementation(dev, CapabilityStaticMember<HIDDeviceCapability>.digitizer) }),
        ("vendorDefined", { try await implementation(dev, CapabilityStaticMember<HIDDeviceCapability>.vendorDefined) }),
        ("pasteboard", { try await implementation(dev, CapabilityStaticMember<HIDDeviceCapability>.pasteboard) }),
    ]
    var caps: [String: String] = [:]
    for (name, lookup) in lookups {
        let t0 = Date()
        switch within(10, lookup) {
        case .success: caps[name] = "ok"
        case .failure(let e): caps[name] = "\(e)"
        }
        note("\(dev.deviceIdentifier) \(name): \(caps[name]!) in \(Int(Date().timeIntervalSince(t0) * 1000))ms")
    }
    return caps
}

private func probeDisplays(_ dev: RemoteDevice) -> Any {
    switch within(10, { try await dev.displayInfo }) {
    case .success(let info):
        return info.displays.map { d -> [String: Any] in
            var m: [String: Any] = [
                "id": d.displayId,
                "width": Int(d.nativeSize.width),
                "height": Int(d.nativeSize.height),
                "external": d.external,
                "backlight": d.backlightState.rawValue,
            ]
            if let a = d.active { m["active"] = a }
            return m
        }
    case .failure(let e):
        return "\(e)"
    }
}

private func pressHome(_ dev: RemoteDevice) -> String {
    let r = within(10) { () -> Bool in
        let b = try await implementation(dev, CapabilityStaticMember<HIDDeviceCapability>.button)
        guard let button = b as? any HIDButton else { throw InputError("button capability is not HIDButton") }
        try button.sendCustomButton(usagePage: 0x0C, usageCode: 0x40, state: .down)
        try await Task.sleep(nanoseconds: 80_000_000)
        try button.sendCustomButton(usagePage: 0x0C, usageCode: 0x40, state: .up)
        button.sendBarrier()
        return true
    }
    switch r {
    case .success: return "ok"
    case .failure(let e): return "\(e)"
    }
}

private func emit(_ obj: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
          let line = String(data: data, encoding: .utf8) else { return }
    print(line)
    fflush(stdout)
}

func runDevices(_ rest: [String]) -> Never {
    let press: String? = rest.firstIndex(of: "-press").map { i in
        guard i + 1 < rest.count, UUID(uuidString: rest[i + 1]) != nil else {
            FileHandle.standardError.write("usage: simcap -devices [-press <identifier>]\n".data(using: .utf8)!)
            exit(2)
        }
        return rest[i + 1].uppercased()
    }
    guard HubHID.available else {
        note("CoreDevice is not installed")
        exit(1)
    }
    Thread.detachNewThread {
        let listed = devicectlDevices()
        // .default is the class DeviceManager.shared uses, which listed only
        // the physical iPhones. The other classes would need their enum case
        // symbols matched before they link.
        let t0 = Date()
        let found = within(15) { () -> [RemoteDevice] in
            let mgr = DeviceManager(serviceConnection: CoreDeviceService.sharedConnection,
                                    allowedDeviceVisibilityClasses: [.default])
            await mgr.waitForPostPluginLoadCheckIn()
            await mgr.awaitFullInitialization()
            return mgr.allDevices()
        }
        guard case .success(let devices) = found else {
            note("CoreDevice: no device list in 15s")
            exit(1)
        }
        note("CoreDevice listed \(devices.count) in \(Int(Date().timeIntervalSince(t0) * 1000))ms, devicectl \(listed.count)")
        var seen = Set<String>()
        for dev in devices {
            let id = dev.deviceIdentifier.uuidString
            seen.insert(id)
            var line: [String: Any] = ["identifier": id]
            if let d = listed[id] {
                line.merge(summary(d)) { a, _ in a }
            } else {
                line["devicectl"] = "not listed"
            }
            line["caps"] = probeCaps(dev)
            line["displays"] = probeDisplays(dev)
            if press == id { line["press"] = pressHome(dev) }
            emit(line)
        }
        // A device devicectl knows and CoreDevice did not hand back is worth
        // seeing too: it says the identifiers do not join, or the class is
        // wrong.
        for (id, d) in listed.sorted(by: { $0.key < $1.key }) where !seen.contains(id) {
            var line: [String: Any] = ["identifier": id, "coreDevice": "not listed"]
            line.merge(summary(d)) { a, _ in a }
            emit(line)
        }
        if let press, !seen.contains(press) {
            note("-press \(press): CoreDevice does not list it")
            exit(1)
        }
        exit(0)
    }
    dispatchMain()
}
