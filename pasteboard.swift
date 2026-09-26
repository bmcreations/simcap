// The simulator's pasteboard through CoreDevice's `pasteboard` capability,
// the one Device Hub syncs the Mac's clipboard through. `simctl pbcopy` and
// `pbpaste` both exit 0 on Xcode 27 and do nothing: CoreSimulatorBridge
// drops the connection 2ms after it opens and the pasteboard stays empty.
//
// Text crosses as a snapshot of an NSPasteboard, so each call goes through a
// private, uniquely named one and never touches the Mac's clipboard.
// Measured on loupe-probe: a set took 11-49ms, a read 3-93ms, and the change
// stream reported each of two sets a second apart.
//
// What this sets is another process's content to iOS. Cmd+V into Home Screen
// Search was refused (pasted: "Paste requires user authorization"), where the
// edit menu's Paste, a secure control, needs no permission. So the server
// types text it means to paste rather than pressing Cmd+V.

import AppKit
import CoreDevice
import Foundation

// iOS's general pasteboard. The name is passed through to pasted inside the
// simulator as it is, so the Mac's "Apple CFPasteboard general" reaches a
// second pasteboard no app reads: pasted logged NotGeneralPasteboard, and
// Search offered no Paste.
private let generalPasteboard = "com.apple.UIKit.pboard.general"

final class HubPasteboard {
    private let pb: any PasteboardProtocol

    private init(_ pb: any PasteboardProtocol) { self.pb = pb }

    // Blocks the calling thread, which must not be the main one, the same
    // way HubHID.open does.
    static func open(udid: String) -> Result<HubPasteboard, InputError> {
        guard HubHID.available else { return .failure(InputError("CoreDevice is not installed")) }
        guard let want = UUID(uuidString: udid) else { return .failure(InputError("bad udid")) }
        return blocking(5) {
            guard let dev = await coreDevice(want) else { throw InputError("CoreDevice does not list \(udid)") }
            let impl = try await implementation(dev, CapabilityStaticMember<HIDDeviceCapability>.pasteboard)
            guard let pb = impl as? any PasteboardProtocol else {
                throw InputError("CoreDevice's pasteboard capability is not PasteboardProtocol")
            }
            return HubPasteboard(pb)
        }
    }

    // text returns the pasteboard's plain text, or "" when it holds none.
    func text() throws -> String {
        try Self.blocking(5) { [pb] in
            let snap = try await pb.currentPasteboardSnapshot(pasteboardName: generalPasteboard, dataPolicy: .allResolved)
            return try Self.string(of: snap)
        }.get()
    }

    func setText(_ s: String) throws {
        try Self.blocking(5) { [pb] in
            let scratch = NSPasteboard.withUniqueName()
            defer { scratch.releaseGlobally() }
            scratch.clearContents()
            scratch.setString(s, forType: .string)
            let snap = try PasteboardSnapshot(from: scratch, dataPolicy: .allResolved)
            _ = try await pb.setPasteboardContents(pasteboardName: generalPasteboard, pasteboardSnapshot: snap)
        }.get()
    }

    // watch calls onChange with the text of each change until the stream
    // ends. A snapshot marked confidential, which is how a password manager
    // copies, is passed as nil: the viewer is told something was copied and
    // not what.
    func watch(_ onChange: @escaping (String?) -> Void) async throws {
        let mon = try await pb.monitorPasteboardChanges(pasteboardName: generalPasteboard, dataPolicy: .allResolved,
                                                        includeInitialState: false)
        defer { mon.invalidate() }
        for try await snap in mon.snapshotStream {
            onChange(snap.containsConfidentialContent ? nil : try Self.string(of: snap))
        }
    }

    private static func string(of snap: PasteboardSnapshot) throws -> String {
        let scratch = NSPasteboard.withUniqueName()
        defer { scratch.releaseGlobally() }
        scratch.clearContents()
        _ = try snap.write(to: scratch)
        return scratch.string(forType: .string) ?? ""
    }

    private static func blocking<T>(_ seconds: Double, _ body: @escaping () async throws -> T) -> Result<T, InputError> {
        var result: Result<T, InputError> = .failure(InputError("CoreDevice: no answer in \(Int(seconds))s"))
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            defer { done.signal() }
            do { result = .success(try await body()) } catch let e as InputError {
                result = .failure(e)
            } catch {
                result = .failure(InputError("CoreDevice: \(error)"))
            }
        }
        _ = done.wait(timeout: .now() + seconds)
        return result
    }
}

// runPasteboardWatch prints the pasteboard each time it changes, one line
// per change: `text <base64 of UTF-8>`, or `confidential` for a copy that
// is marked so. It runs beside a session's video and exits when stdin
// closes, which is how the parent says it is done.
func runPasteboardWatch(udid: String) -> Never {
    Thread.detachNewThread {
        while readLine() != nil {}
        exit(0)
    }
    Thread.detachNewThread {
        let pb: HubPasteboard
        switch HubPasteboard.open(udid: udid) {
        case .success(let p): pb = p
        case .failure(let e):
            FileHandle.standardError.write("simcap: pasteboard: \(e)\n".data(using: .utf8)!)
            exit(1)
        }
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            defer { done.signal() }
            do {
                try await pb.watch { text in
                    if let text {
                        print("text \(Data(text.utf8).base64EncodedString())")
                    } else {
                        print("confidential")
                    }
                    fflush(stdout)
                }
            } catch {
                FileHandle.standardError.write("simcap: pasteboard: \(error)\n".data(using: .utf8)!)
            }
        }
        done.wait()
        exit(1)
    }
    dispatchMain()
}
