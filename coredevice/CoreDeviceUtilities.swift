// Declarations only, matching the mangled names CoreDeviceUtilities.framework
// exports on Xcode 27, for the types that keep that module's name (most of
// what CoreDevice re-exports is declared in CoreDevice.swift under
// CoreDevice's). Compiled into a .swiftmodule and never linked: simcap links
// the real framework.
import Foundation

// What a foldable's hinge reports, as Device Hub's hinge readout shows it.
public struct HingeAngleStreamConfig {
  public init(changeThreshold: Measurement<UnitAngle>, updateInterval: Duration) { fatalError() }
}

public struct DeviceHingeAngleSnapshot {
  public var angle: Measurement<UnitAngle> { fatalError() }
  public var isAngleValid: Bool { fatalError() }
  public var timestamp: Double { fatalError() }
}
