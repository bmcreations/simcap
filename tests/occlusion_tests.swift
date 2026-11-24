import Foundation

@main
struct OcclusionTests {
    static var failures = 0
    static func check(_ ok: Bool, _ what: String) {
        if !ok { failures += 1; print("FAIL", what) }
    }

    static func main() {
        // A native element: only another element at its centre covers it.
        check(!occluded(.element, onPage: false), "native element hit itself")
        check(occluded(.other, onPage: false), "native element under another")
        check(!occluded(.nothing, onPage: false), "a hit on nothing proves nothing for a native element")
        check(!occluded(.unplaced, onPage: false), "an unplaced hit on a native element is left to find the page")

        // A page element, tested once its page is in the tree.
        check(!occluded(.element, onPage: true), "page element hit itself")
        check(occluded(.other, onPage: true), "page element under Safari's toolbar")
        check(occluded(.nothing, onPage: true), "page element centred below its web view")
        check(occluded(.unplaced, onPage: true), "page element centred under the status bar")

        print(failures == 0 ? "occlusion: all passed" : "occlusion: \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
