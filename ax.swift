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

// isWebContent reports whether pid is the process WebKit renders a
// WKWebView's page in. The simulator's processes are this Mac's, so the
// path is readable here: on iOS 27.2 it ends
// WebContentExtension.appex/com.apple.WebKit.WebContent.
private func isWebContent(_ pid: Int32) -> Bool {
    var buf = [CChar](repeating: 0, count: 4096)
    guard pid > 0, proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return false }
    return (String(cString: buf) as NSString).lastPathComponent == "com.apple.WebKit.WebContent"
}

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
        // A web page's element carries its web area's frame: a tap reaches
        // the page only inside it.
        var clip: CGRect?
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

    // hit is the element at a point, in the screen's points, as one node in
    // the shape dump gives, without children; [:] when the point hits
    // nothing. Some elements are on screen and reachable only this way: with
    // the keyboard up, the edit menu's items have no parent, so dump's walk
    // from the application never meets them. Measured in Flipcash on an
    // iPhone 17 simulator, iOS 27: Paste hit as an AXStaticText at
    // (20,444) 70x44 while dump had no trace of it. Each call took about 5ms.
    func hit(_ pt: CGPoint) throws -> [String: Any] {
        typealias AtFn = @convention(c) (AnyObject, Selector, CGPoint, UInt32, AnyObject) -> Unmanaged<AnyObject>?
        let sel = NSSelectorFromString("objectAtPoint:displayId:bridgeDelegateToken:")
        guard let imp = class_getMethodImplementation(type(of: translator), sel)
        else { throw InputError("AXPTranslator has no objectAtPoint") }
        let at = unsafeBitCast(imp, to: AtFn.self)
        guard let found = at(translator, sel, pt, 0, token)?.takeUnretainedValue() as? NSObject else { return [:] }
        found.setValue(token, forKey: "bridgeDelegateToken")
        guard let e = translator.perform(NSSelectorFromString("macPlatformElementFromTranslation:"), with: found)?
            .takeUnretainedValue() as? NSObject
        else { return [:] }
        _ = stamp(e)
        return fields(e)
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
        var screen = all.first?.frame ?? .null
        if let lit = litDisplay(), let spec = panelSpec(lit.id), spec.scale > 0 {
            let (uw, uh) = turned(lit.width, lit.height, lit.turn)
            screen = CGRect(x: 0, y: 0, width: Double(uw) / spec.scale, height: Double(uh) / spec.scale)
            tree.fields["frame"] = [0, 0, screen.width, screen.height]
        }
        let unplaced = markOccluded(all, all: all, screen: screen)
        let webs = webAreas(unplaced.map(\.hit) + probe(all, screen: screen))
        guard !webs.isEmpty else { return tree.json }
        var added: [Elem] = []
        for w in webs { tree.children.append(readWebArea(w, parent: tree, into: &added)) }
        all += added
        // Whatever the first pass could not place may sit under a page,
        // which the second pass can now place.
        _ = markOccluded(added + unplaced.map(\.el), all: all, screen: screen, hits: unplaced)
        return tree.json
    }

    // Web content is missing from the walk above. WebKit renders a
    // WKWebView's page, Safari's included, in its own process, and the
    // translator never links the two: Safari's application lists only its
    // toolbar, and the page's root, the web area, has no parent and no
    // accessibilityChildren. A hit test on the page does reach it, and
    // descendants below the web area answer accessibilityChildren as usual.
    // Measured in Safari on tv.apple.com/search, iPhone 18 Pro simulator,
    // iOS 27.2: the dump held Back, Page Menu, Address, Tabs and one more
    // button; a hit at (50,255) found the Browse heading in pid
    // com.apple.WebKit.WebContent, whose parents ended at an AXGroup titled
    // Apple TV, frame (0,62) 402x714, with no children.
    //
    // webAreas climbs each hit in a WebContent process to its topmost
    // ancestor, the web area, and keeps each web area once. A hit in any
    // other process is skipped before the climb, which is one request per
    // parent: on a native screen every probe that misses the walk's leaves
    // lands in the app's own process.
    private func webAreas(_ hits: [NSObject]) -> [NSObject] {
        var found: [NSObject] = []
        for hit in hits {
            guard let pid = (hit.value(forKey: "pid") as? NSNumber)?.int32Value, isWebContent(pid) else { continue }
            hit.setValue(token, forKey: "bridgeDelegateToken")
            guard var cur = translator.perform(NSSelectorFromString("macPlatformElementFromTranslation:"), with: hit)?
                .takeUnretainedValue() as? NSObject
            else { continue }
            for _ in 0..<maxDepth {
                guard let parent = cur.value(forKey: "accessibilityParent") as? NSObject else { break }
                cur = parent
            }
            guard let t = stamp(cur), !found.contains(where: { stamp($0)?.isEqual(t) ?? false }) else { continue }
            found.append(cur)
        }
        return found
    }

    // probe hit-tests a grid over the screen for content the walk never
    // met, skipping points a leaf the walk did meet already covers: on a
    // native screen most of the grid lands in rows and buttons and costs
    // nothing. A point that finds an element the walk has is dropped.
    // 4x8 cells, 100x109 points on an iPhone 18 Pro: a web view smaller than
    // a cell can fall between the points.
    private func probe(_ all: [Elem], screen: CGRect) -> [NSObject] {
        guard !screen.isNull, screen.width > 0, screen.height > 0 else { return [] }
        typealias AtFn = @convention(c) (AnyObject, Selector, CGPoint, UInt32, AnyObject) -> Unmanaged<AnyObject>?
        let sel = NSSelectorFromString("objectAtPoint:displayId:bridgeDelegateToken:")
        guard let imp = class_getMethodImplementation(type(of: translator), sel) else { return [] }
        let at = unsafeBitCast(imp, to: AtFn.self)
        let leaves = all.dropFirst().compactMap { $0.children.isEmpty ? $0.frame : nil }
        var covered: [CGRect] = []
        var hits: [NSObject] = []
        let cols = 4, rows = 8
        for r in 0..<rows {
            for c in 0..<cols {
                let pt = CGPoint(x: screen.minX + screen.width * (Double(c) + 0.5) / Double(cols),
                                 y: screen.minY + screen.height * (Double(r) + 0.5) / Double(rows))
                if leaves.contains(where: { $0.contains(pt) }) || covered.contains(where: { $0.contains(pt) }) { continue }
                guard let hit = at(translator, sel, pt, 0, token)?.takeUnretainedValue() as? NSObject,
                      place(hit, in: all) == nil
                else { continue }
                hits.append(hit)
                // Every other point on the same page finds the same web area.
                if let web = webAreas([hit]).first,
                   let f = (web.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue {
                    covered.append(f)
                }
            }
        }
        return hits
    }

    // The web area answers no accessibilityChildren; a search for its
    // immediate descendants gives them, 6 on tv.apple.com/search, and the
    // walk takes over from there.
    //
    // Only a WebKit element can be asked this. UIKit answers the same search
    // on an application element by throwing from rangeOfString: inside
    // -[UIApplicationAccessibility _accessibilityElementsForSearchParameter:],
    // which aborted Safari and then SpringBoard on that simulator.
    //
    // focused is dropped from the page: WebKit answers AXFocused true on
    // every element of it, the web area too, while Safari's Back button
    // answers false, and the web area's AXFocusedUIElement is nil. Measured
    // on the Sign In button of tv.apple.com/search with the keyboard down.
    private func readWebArea(_ e: NSObject, parent: Elem, into all: inout [Elem]) -> Elem {
        let start = all.count
        let frame = (e.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue
        let el = Elem(translation: stamp(e))
        defer {
            for page in all[start...] {
                page.fields["focused"] = nil
                if page !== el { page.clip = frame }
            }
        }
        el.parent = parent
        all.append(el)
        el.fields = fields(e)
        el.frame = frame
        var kids = (e.value(forKey: "accessibilityChildren") as? [NSObject]) ?? []
        if kids.isEmpty {
            let search: [String: Any] = [
                "AXSearchKey": "AXAnyTypeSearchKey",
                "AXDirection": "AXDirectionNext",
                "AXImmediateDescendantsOnly": true,
                "AXResultsLimit": 1000,
            ]
            kids = (e.perform(NSSelectorFromString("accessibilityAttributeValue:forParameter:"),
                              with: "AXUIElementsForSearchPredicate", with: search)?
                .takeUnretainedValue() as? [NSObject]) ?? []
        }
        el.children = kids.map { read($0, parent: el, depth: 2, into: &all) }
        return el
    }

    // Every element carries its own translation, and each needs the token, or
    // its requests go to no delegate and come back empty.
    private func stamp(_ e: NSObject) -> NSObject? {
        let t = e.value(forKey: "translation") as? NSObject
        t?.setValue(token, forKey: "bridgeDelegateToken")
        return t
    }

    // fields are an element's own attributes, in the shape -input's ui gives.
    private func fields(_ e: NSObject) -> [String: Any] {
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
        }
        if let enabled = e.value(forKey: "accessibilityEnabled") as? Bool, !enabled { n["disabled"] = true }
        return n
    }

    private func read(_ e: NSObject, parent: Elem?, depth: Int, into all: inout [Elem]) -> Elem {
        let el = Elem(translation: stamp(e))
        el.parent = parent
        all.append(el)
        el.fields = fields(e)
        if let f = (e.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue { el.frame = f }
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
    // one that it did. A hit on nothing proves nothing, and a hit that
    // cannot be placed is returned with its element: on a web page it is
    // how dump finds the page, and once the page is in the tree the hit is
    // tried again from `hits` rather than tested a second time.
    //
    // A page element whose centre is outside its web area is occluded
    // without a hit test, which finds nothing there. Measured on
    // tv.apple.com/search: Kids & Family's centre sat at y 782, between the
    // web area's bottom at 776 and Safari's toolbar at 792; a hit test there
    // found nothing, and a tap there did not follow the link. At the top
    // edge, the page's search field scrolled under the status bar, centre at
    // y 39 against the web area's top at 62, took no focus from a tap.
    private func markOccluded(_ els: [Elem], all: [Elem], screen: CGRect,
                              hits: [(el: Elem, hit: NSObject)] = []) -> [(el: Elem, hit: NSObject)] {
        typealias AtFn = @convention(c) (AnyObject, Selector, CGPoint, UInt32, AnyObject) -> Unmanaged<AnyObject>?
        let sel = NSSelectorFromString("objectAtPoint:displayId:bridgeDelegateToken:")
        guard let imp = class_getMethodImplementation(type(of: translator), sel) else { return [] }
        let at = unsafeBitCast(imp, to: AtFn.self)
        var unplaced: [(el: Elem, hit: NSObject)] = []
        for el in els where el !== all.first {
            guard let f = el.frame, f.width > 0, f.height > 0 else { continue }
            let mid = CGPoint(x: f.midX, y: f.midY)
            if !screen.isNull, !screen.contains(mid) {
                el.fields["occluded"] = true
                continue
            }
            if let clip = el.clip, !clip.contains(mid) {
                el.fields["occluded"] = true
                continue
            }
            guard let hit = hits.first(where: { $0.el === el })?.hit
                ?? at(translator, sel, CGPoint(x: f.midX, y: f.midY), 0, token)?.takeUnretainedValue() as? NSObject
            else { continue }
            guard let top = place(hit, in: all) else {
                unplaced.append((el, hit))
                continue
            }
            var cur: Elem? = top
            while let c = cur, c !== el { cur = c.parent }
            if cur == nil { el.fields["occluded"] = true }
        }
        return unplaced
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
