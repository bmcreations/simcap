// Read a foldable's hinge angle through CoreDevice's motion capability, the
// one Device Hub's hinge readout uses. A hinge write (sendHinge) says where
// the hinge should go; this says where it is. The line command (input.swift):
//
//   hingeangle   -> ok DEGREES | ok none
//
// `none` means the device reports no hinge, which is every simulator but a
// foldable.

import CoreDevice
import CoreDeviceUtilities
import Foundation

enum HingeReader {
    // angle opens the hinge stream, takes the first valid reading and closes
    // it. nil means the device has no hinge. A reading that has not come in
    // `seconds` throws.
    static func angle(_ device: RemoteDevice, seconds: Double = 2) throws -> Double? {
        var out: Result<Double?, Error> = .failure(InputError("hinge angle: no answer in \(seconds)s"))
        let done = DispatchSemaphore(value: 0)
        let task = Task.detached {
            defer { done.signal() }
            do {
                let c = try await implementation(device, CapabilityStaticMember<MonitorMotionCapability>.monitorMotion)
                guard let motion = c as? any MonitorMotionProtocol else {
                    out = .failure(InputError("CoreDevice capability is not MonitorMotion"))
                    return
                }
                let mgr = try await motion.motionManager()
                guard mgr.supportsHingeAngle else {
                    out = .success(nil)
                    return
                }
                let config = HingeAngleStreamConfig(changeThreshold: Measurement(value: 0.5, unit: .degrees),
                                                    updateInterval: .milliseconds(50))
                for try await batch in try await mgr.monitorHingeAngle(config: config) {
                    if let s = batch.last(where: { $0.isAngleValid }) {
                        out = .success(s.angle.converted(to: .degrees).value)
                        return
                    }
                }
                out = .failure(InputError("hinge angle: the stream ended without a reading"))
            } catch {
                out = .failure(InputError("CoreDevice: \(error)"))
            }
        }
        if done.wait(timeout: .now() + seconds) == .timedOut { task.cancel() }
        return try out.get()
    }
}
