// The `ui` input command: the frontmost app's accessibility tree, through
// AccessibilityPlatformTranslation's AXPTranslator, the path Xcode's own
// Accessibility Inspector uses for a simulator.
//
// AXPTranslator turns iOS accessibility into macOS NSAccessibility elements,
// and fetches each thing it needs by handing a request to a delegate, which
// forwards it to the simulator with SimDevice's
// sendAccessibilityRequestAsync. Frames come back in points, relative to the
// screen; the server scales them to pixels.
//
// Output is one JSON object: {"role","subrole","label","value","id",
// "frame":[x,y,w,h],"focused","disabled","occluded","children"}, with empty and false
// fields left out. Mapping it onto loupe's
// node shape happens in Go, where it can be tested.

import CoreGraphics
import Foundation
import ObjectiveC

private let axFramework = "/System/Library/PrivateFrameworks/AccessibilityPlatformTranslation.framework/AccessibilityPlatformTranslation"

// A tree deeper than this is a cycle, not an interface.
private let maxDepth = 60

final class AXTokenDelegate: NSObject {
    let device: NSObject
    let replies = DispatchQueue(label: "simcap.ax.replies")

    init(device: NSObject) { self.device = device }

    // The translator calls this for every request it makes and blocks on the
    // block's result, so the reply has to arrive on a queue other than the
    // one asking.
    @objc(accessibilityTranslationDelegateBridgeCallbackWithToken:)
    func bridgeCallback(token: NSString) -> Any {
        let device = self.device, replies = self.replies
        let block: @convention(block) (AnyObject) -> AnyObject? = { request in
            typealias Fn = @convention(c) (AnyObject, Selector, AnyObject, AnyObject, AnyObject) -> Void
            let sel = NSSelectorFromString("sendAccessibilityRequestAsync:completionQueue:completionHandler:")
            guard let imp = class_getMethodImplementation(type(of: device), sel) else { return nil }
            let done = DispatchSemaphore(value: 0)
            var response: AnyObject?
            let completion: @convention(block) (AnyObject?) -> Void = { r in response = r; done.signal() }
            unsafeBitCast(imp, to: Fn.self)(device, sel, request, replies, completion as AnyObject)
            if done.wait(timeout: .now() + 5) == .timedOut { return nil }
            return response
        }
        return block as AnyObject
    }

    // Frames are already in the simulator screen's points; there is no macOS
    // window for them to be relative to.
    @objc(accessibilityTranslationConvertPlatformFrameToSystem:withToken:)
    func convertFrame(_ rect: CGRect, token: NSString) -> CGRect { rect }

    @objc(accessibilityTranslationRootParentWithToken:)
    func rootParent(token: NSString) -> AnyObject? { nil }
}

final class AXTree {
    let translator: NSObject
    let delegate: AXTokenDelegate
    let token = UUID().uuidString as NSString

    init(device: NSObject) throws {
        guard dlopen(axFramework, RTLD_NOW | RTLD_GLOBAL) != nil,
              let cls = NSClassFromString("AXPTranslator") as? NSObject.Type,
              let shared = cls.perform(NSSelectorFromString("sharedInstance"))?.takeUnretainedValue() as? NSObject
        else { throw InputError("AccessibilityPlatformTranslation has no AXPTranslator") }
        translator = shared
        delegate = AXTokenDelegate(device: device)
        translator.setValue(delegate, forKey: "bridgeTokenDelegate")
        translator.setValue(true, forKey: "supportsDelegateTokens")
        translator.setValue(true, forKey: "accessibilityEnabled")
    }

    // One element while the tree is being read: its fields, its
    // translation for matching a hit test against, and its place in the tree.
    private final class Elem {
        var fields: [String: Any] = [:]
        let translation: NSObject?
        weak var parent: Elem?
        var children: [Elem] = []
        var frame: CGRect?
        init(translation: NSObject?) { self.translation = translation }

        var json: [String: Any] {
            var d = fields
            if !children.isEmpty { d["children"] = children.map(\.json) }
            return d
        }
    }

    // frontPid is the process behind the frontmost application: SpringBoard
    // on the Home Screen. Reclaiming restarts SpringBoard and ends every app,
    // and this is what names the one to reopen afterwards.
    func frontPid() throws -> Int32 {
        let translation = try front()
        guard let pid = (translation.value(forKey: "pid") as? NSNumber)?.int32Value, pid > 0
        else { throw InputError("frontmost application has no pid") }
        return pid
    }

    private func front() throws -> NSObject {
        typealias FrontFn = @convention(c) (AnyObject, Selector, UInt32, AnyObject) -> Unmanaged<AnyObject>?
        let frontSel = NSSelectorFromString("frontmostApplicationWithDisplayId:bridgeDelegateToken:")
        guard let imp = class_getMethodImplementation(type(of: translator), frontSel),
              let translation = unsafeBitCast(imp, to: FrontFn.self)(translator, frontSel, 0, token)?.takeUnretainedValue() as? NSObject
        else { throw InputError("no frontmost application") }
        translation.setValue(token, forKey: "bridgeDelegateToken")
        return translation
    }

    func dump() throws -> [String: Any] {
        let translation = try front()
        guard let root = translator.perform(NSSelectorFromString("macPlatformElementFromTranslation:"), with: translation)?
            .takeUnretainedValue() as? NSObject
        else { throw InputError("no element for the frontmost application") }
        var all: [Elem] = []
        let tree = read(root, parent: nil, depth: 0, into: &all)
        // The root reports the outer panel's size even while the Duo's inner
        // panel is lit, 466x678 points against the inner's 951x669 upright.
        // The frames are already upright -- About in Settings read
        // (341,304) 525x50 on loupe-duo unfolded, where the screenshot has
        // it -- so only the root and the occlusion bounds take the lit size.
        guard let lit = litDisplay(), let spec = panelSpec(lit.id), spec.scale > 0 else {
            markOccluded(all, screen: all.first?.frame ?? .null)
            return tree.json
        }
        let (uw, uh) = turned(lit.width, lit.height, lit.turn)
        let screen = CGRect(x: 0, y: 0, width: Double(uw) / spec.scale, height: Double(uh) / spec.scale)
        markOccluded(all, screen: screen)
        tree.fields["frame"] = [0, 0, screen.width, screen.height]
        return tree.json
    }

    // Every element carries its own translation, and each needs the token, or
    // its requests go to no delegate and come back empty.
    private func stamp(_ e: NSObject) -> NSObject? {
        let t = e.value(forKey: "translation") as? NSObject
        t?.setValue(token, forKey: "bridgeDelegateToken")
        return t
    }

    private func read(_ e: NSObject, parent: Elem?, depth: Int, into all: inout [Elem]) -> Elem {
        let el = Elem(translation: stamp(e))
        el.parent = parent
        all.append(el)
        func str(_ key: String) -> String? {
            guard let v = e.value(forKey: key) else { return nil }
            let s = (v as? String) ?? (v as? NSAttributedString)?.string ?? (v is NSNull ? nil : "\(v)")
            return (s?.isEmpty ?? true) ? nil : s
        }
        var n: [String: Any] = [:]
        if let v = str("accessibilityRole") { n["role"] = v }
        // AXSecureTextField marks a password field, which /api/input needs
        // to redact what it types there.
        if let v = str("accessibilitySubrole") { n["subrole"] = v }
        if let focused = e.value(forKey: "accessibilityFocused") as? Bool, focused { n["focused"] = true }
        if let v = str("accessibilityLabel") { n["label"] = v }
        if let v = str("accessibilityValue") { n["value"] = v }
        if let v = str("accessibilityIdentifier") { n["id"] = v }
        if let f = (e.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue {
            n["frame"] = [f.origin.x, f.origin.y, f.size.width, f.size.height]
            el.frame = f
        }
        if let enabled = e.value(forKey: "accessibilityEnabled") as? Bool, !enabled { n["disabled"] = true }
        el.fields = n
        if depth < maxDepth, let kids = e.value(forKey: "accessibilityChildren") as? [NSObject] {
            el.children = kids.map { read($0, parent: el, depth: depth + 1, into: &all) }
        }
        return el
    }

    // The tree holds everything the app has, including what another view
    // covers: with Settings' search open, the root list is still there
    // underneath, and a tap on its General row lands on the search results.
    // An element is marked occluded when a tap at its centre cannot reach it:
    // the centre is off the screen, or a hit test there finds another
    // element that is neither it nor inside it.
    //
    // This is one-way. The hit test follows the accessibility tree, not the
    // pixels, so a view that draws over an element without being an element
    // itself -- the blank area under Settings' search results -- lets the
    // hit through to the element underneath, which then reads as visible.
    // Measured on that screen: General and Accessibility, under result rows,
    // were marked; Appearance, under the blank area, was not.
    //
    // A hit the dump did not reach is placed by walking up its parents to
    // one that it did. A hit on nothing proves nothing.
    private func markOccluded(_ all: [Elem], screen: CGRect) {
        typealias AtFn = @convention(c) (AnyObject, Selector, CGPoint, UInt32, AnyObject) -> Unmanaged<AnyObject>?
        let sel = NSSelectorFromString("objectAtPoint:displayId:bridgeDelegateToken:")
        guard let imp = class_getMethodImplementation(type(of: translator), sel) else { return }
        let at = unsafeBitCast(imp, to: AtFn.self)
        for el in all.dropFirst() {
            guard let f = el.frame, f.width > 0, f.height > 0 else { continue }
            if !screen.isNull, !screen.contains(CGPoint(x: f.midX, y: f.midY)) {
                el.fields["occluded"] = true
                continue
            }
            guard let hit = at(translator, sel, CGPoint(x: f.midX, y: f.midY), 0, token)?.takeUnretainedValue() as? NSObject,
                  let top = place(hit, in: all)
            else { continue }
            var cur: Elem? = top
            while let c = cur, c !== el { cur = c.parent }
            if cur == nil { el.fields["occluded"] = true }
        }
    }

    private func place(_ hit: NSObject, in all: [Elem]) -> Elem? {
        hit.setValue(token, forKey: "bridgeDelegateToken")
        if let e = all.first(where: { $0.translation?.isEqual(hit) ?? false }) { return e }
        var cur = translator.perform(NSSelectorFromString("macPlatformElementFromTranslation:"), with: hit)?
            .takeUnretainedValue() as? NSObject
        for _ in 0..<maxDepth {
            guard let c = cur, let parent = c.value(forKey: "accessibilityParent") as? NSObject else { return nil }
            if let t = stamp(parent), let e = all.first(where: { $0.translation?.isEqual(t) ?? false }) { return e }
            cur = parent
        }
        return nil
    }
}
