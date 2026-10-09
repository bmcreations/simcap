// Declarations only, matching the mangled names
// CoreDeviceMediaStreamSupport.framework exports on Xcode 27, nested inside
// CoreDevice.framework/Versions/A/Frameworks. Compiled into a .swiftmodule
// and never linked: simcap links the real framework. wifi.swift is the
// only user.
import Foundation
import QuartzCore
import CoreDevice

public enum MediaStreamDirection: UInt32 { case send, receive }
public protocol MediaStreamConfiguration { var direction: MediaStreamDirection { get } }
public struct VideoStreamReceiveConfiguration { public var resolution: CGSize { fatalError() } }
public struct VideoStreamSendConfiguration { public var resolution: CGSize { fatalError() } }
public enum VideoStreamConfiguration {
  case receive(VideoStreamReceiveConfiguration)
  case send(VideoStreamSendConfiguration)
  public static func receiveMirroredPrimary(layer: CALayer, timeout: UInt) -> VideoStreamConfiguration { fatalError() }
}
public struct VideoStreamAttributes {
  public var contentsRect: CGRect { fatalError() }
  public var ratio: CGSize { fatalError() }
  public var scaleFactor: Float { fatalError() }
}
public enum VideoStreamEvent {
  case receivedFirstFrame
  case receivedLastDecodedFrame(Data)
  case remoteVideoAttributesChanged(VideoStreamAttributes)
}
public protocol MediaStreamProtocol: Actor {
  associatedtype Configuration
  associatedtype Event
  var configuration: Configuration { get }
  func activate() async throws -> AsyncThrowingStream<Event, Error>
  func invalidate() async
}
public protocol VideoStream: MediaStreamProtocol where Configuration == VideoStreamConfiguration, Event == VideoStreamEvent {
  func requestLastDecodedFrame() async
}
public actor MediaStreamSession {
  public init(clientSessionID: UUID) { fatalError() }
  public final func makeVideoStream(withConfiguration: VideoStreamConfiguration, fromRemoteDevice: RemoteDevice) async throws -> any VideoStream { fatalError() }
}
