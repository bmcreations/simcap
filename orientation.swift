// Rotate a simulator through CoreDevice's orientation-control capability, the
// one Device Hub's rotate buttons call. The line commands (input.swift):
//
//   orient get                 -> ok NAME LOCKED   (NAME is a DeviceOrientation)
//   orient set NAME            -> ok NAME LOCKED
//   orient rotate left|right   -> ok NAME LOCKED
//
// NAME is portrait, portraitUpsideDown, landscapeLeft or landscapeRight (get
// can also answer faceUp, faceDown or unknown). The reply carries the
// orientation CoreDevice reports after the call.

import CoreDevice
import Foundation

final class HubOrientation {
    let control: any OrientationControl
    init(_ control: any OrientationControl) { self.control = control }

    static func open(udid: String) -> Result<HubOrientation, InputError> {
        guard HubHID.available else { return .failure(InputError("CoreDevice is not installed")) }
        guard let want = UUID(uuidString: udid) else { return .failure(InputError("bad udid")) }
        var result: Result<HubOrientation, InputError> = .failure(InputError("CoreDevice: no answer in 10s"))
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            defer { done.signal() }
            guard let dev = await coreDevice(want) else {
                result = .failure(InputError("CoreDevice does not list \(udid)"))
                return
            }
            do {
                let c = try await implementation(dev, CapabilityStaticMember<OrientationControlCapability>.orientationControl)
                guard let control = c as? any OrientationControl else {
                    result = .failure(InputError("CoreDevice capability is not OrientationControl"))
                    return
                }
                result = .success(HubOrientation(control))
            } catch {
                result = .failure(InputError("CoreDevice: \(error)"))
            }
        }
        _ = done.wait(timeout: .now() + 10)
        return result
    }

    // run waits for one async call. A call that never returns is cut at 5s.
    private func run(_ call: @escaping @Sendable () async throws -> OrientationInfo) throws -> String {
        var out: Result<OrientationInfo, Error> = .failure(InputError("orientation: no answer in 5s"))
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            defer { done.signal() }
            do { out = .success(try await call()) } catch { out = .failure(error) }
        }
        _ = done.wait(timeout: .now() + 5)
        let info = try out.get()
        return "\(info.currentDeviceOrientation.rawValue) \(info.currentDeviceOrientationLocked ? "locked" : "unlocked")"
    }

    func handle(_ f: [Substring]) throws -> String {
        let c = control
        switch f.count > 1 ? f[1] : "" {
        case "get":
            return try run { try await c.currentDeviceOrientation() }
        case "set":
            guard f.count == 3, let o = DeviceOrientation(rawValue: String(f[2])) else {
                throw InputError("orient set portrait|portraitUpsideDown|landscapeLeft|landscapeRight")
            }
            return try run { try await c.changeDeviceOrientation(o) }
        case "rotate":
            guard f.count == 3, let d = DeviceOrientationRotationDirection(rawValue: String(f[2])) else {
                throw InputError("orient rotate left|right")
            }
            return try run { try await c.rotate(direction: d) }
        default:
            throw InputError("orient get | set NAME | rotate left|right")
        }
    }
}
