// Declarations only, matching the mangled names CoreDevice.framework exports
// on Xcode 27. Compiled into a .swiftmodule and never linked: simcap
// links the real framework.
import AppKit
import Foundation

public enum HIDButtonState: UInt8 { case up, down }

public struct Capability {}

public protocol DeviceCapabilityProtocol {}

public protocol HIDButton: DeviceCapabilityProtocol {
  func sendCustomButton(usagePage: Int, usageCode: Int, state: HIDButtonState) throws
  func sendBarrier()
}

public protocol DeviceCapability {
  associatedtype ProtocolType
  associatedtype ImplType
}

public struct HIDDeviceCapability: DeviceCapability {
  public typealias ProtocolType = Any
  public typealias ImplType = Any
}
public struct ButtonHIDCapability: DeviceCapability {
  public typealias ProtocolType = Any
  public typealias ImplType = Any
}

public struct CapabilityStaticMember<A> {}
extension CapabilityStaticMember where A == HIDDeviceCapability {
  public static var button: CapabilityStaticMember<ButtonHIDCapability> { fatalError() }
}

open class RemoteDevice {
  open var deviceIdentifier: UUID { get { fatalError() } set {} }
  open func getImplementation<A: DeviceCapability>(for: CapabilityStaticMember<A>) async throws -> A.ProtocolType { fatalError() }
}

public protocol CoreDeviceServiceConnection {}
public struct CoreDeviceService {
  public static var sharedConnection: any CoreDeviceServiceConnection { fatalError() }
}
public enum DeviceVisibilityClass: String, Hashable, CaseIterable {
  case `default`, simulators, devicesBeingProvisioned, wirelessPairableDevices
}

open class DeviceManager {
  public init(serviceConnection: any CoreDeviceServiceConnection, allowedDeviceVisibilityClasses: Set<DeviceVisibilityClass>) { fatalError() }
  open func awaitFullInitialization() async {}
  public static var shared: DeviceManager { fatalError() }
  public final func allDevices() -> [RemoteDevice] { fatalError() }
  open func waitForPostPluginLoadCheckIn() async {}
}

// Exported by CoreDeviceUtilities under the CoreDevice module name.
public struct HIDKeyboardUsageCode {
  public init(rawValue: UInt16) { fatalError() }
}
public protocol HIDKeyboard: DeviceCapabilityProtocol {
  func send(key: HIDKeyboardUsageCode, state: HIDButtonState) throws
  func sendBarrier()
}
public struct KeyboardHIDCapability: DeviceCapability {
  public typealias ProtocolType = Any
  public typealias ImplType = Any
}
extension CapabilityStaticMember where A == HIDDeviceCapability {
  public static var keyboard: CapabilityStaticMember<KeyboardHIDCapability> { fatalError() }
}

// The touch digitizer, served by dtuhidd beside the button and keyboard.
public enum DigitizerEventType { case start, position, end }
public enum DigitizerEdge { case none, top, bottom, left, right }
public enum DigitizerTarget {
  case mainScreen, display1, display2, display3, display4, display5, display6, display7, display8, display9, display10
}
public struct DigitizerPoint {
  public init(x: Double, y: Double) { fatalError() }
}
public protocol HIDDigitizer: DeviceCapabilityProtocol {
  func send(pointOne: DigitizerPoint, pointTwo: DigitizerPoint?, eventType: DigitizerEventType, edge: DigitizerEdge, target: DigitizerTarget) throws
  func sendBarrier()
}
public struct DigitizerHIDCapability: DeviceCapability {
  public typealias ProtocolType = Any
  public typealias ImplType = Any
}
extension CapabilityStaticMember where A == HIDDeviceCapability {
  public static var digitizer: CapabilityStaticMember<DigitizerHIDCapability> { fatalError() }
}

// The pasteboard, which Device Hub syncs through. The snapshot types live in
// CoreDeviceUtilities and are mangled under that module; the error lives
// there too and is mangled under this one, so each names where its symbols
// say it was defined.
@available(macOS 10.10, *)
@_originallyDefinedIn(module: "CoreDevice", macOS 10.10)
public struct CoreDeviceError: Error {}

@available(macOS 10.10, *)
@_originallyDefinedIn(module: "CoreDeviceUtilities", macOS 10.10)
public enum PasteboardDataInclusionPolicy {
  case allPromised, allResolved, matchSource, promiseSecondary
  case thresholdData(Int64)
}

@available(macOS 10.10, *)
@_originallyDefinedIn(module: "CoreDeviceUtilities", macOS 10.10)
public struct PasteboardSnapshot {
  public init(from: NSPasteboard, dataPolicy: PasteboardDataInclusionPolicy) throws(CoreDeviceError) { fatalError() }
  public func write(to: NSPasteboard) throws(CoreDeviceError) -> Int { fatalError() }
  public var containsConfidentialContent: Bool { fatalError() }
}

public final class PasteboardMonitorSession {
  public var snapshotStream: AsyncThrowingStream<PasteboardSnapshot, Error> { fatalError() }
  public func invalidate() {}
}

public protocol PasteboardProtocol: DeviceCapabilityProtocol {
  func currentPasteboardSnapshot(pasteboardName: String, dataPolicy: PasteboardDataInclusionPolicy) async throws(CoreDeviceError) -> PasteboardSnapshot
  func monitorPasteboardChanges(pasteboardName: String, dataPolicy: PasteboardDataInclusionPolicy, includeInitialState: Bool) async throws(CoreDeviceError) -> PasteboardMonitorSession
  func setPasteboardContents(pasteboardName: String, pasteboardSnapshot: PasteboardSnapshot) async throws(CoreDeviceError) -> PasteboardSnapshot
}
public struct PasteboardCapability: DeviceCapability {
  public typealias ProtocolType = Any
  public typealias ImplType = Any
}
extension CapabilityStaticMember where A: DeviceCapability {
  public static var pasteboard: CapabilityStaticMember<PasteboardCapability> { fatalError() }
}
