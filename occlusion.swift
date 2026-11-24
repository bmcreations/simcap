// CentreHit is what the hit test at an element's centre found, and
// occluded(_:onPage:) is whether a tap there cannot reach the element. Both
// are for AXTree.markOccluded, kept out of ax.swift so the tests build without
// the private frameworks it loads.
enum CentreHit {
    case nothing   // no element at the point
    case unplaced  // an element the dump did not reach, under none it did
    case element   // the element itself, or one inside it
    case other     // an element the dump reached that is neither
}

// For a native element only another element at its centre says so: a hit on
// nothing proves nothing, and an unplaced hit is how dump finds a web page.
//
// A page element is tested once its page is in the tree, so either of those
// means the centre is outside the page. A page that scrolls as a whole
// document has a web area as tall as the document, so the web area does not
// clip it. Measured on an iPhone 18 Pro simulator, iOS 27.2: a button below
// its 400 pt web view, and Item 28 of a long Safari page at y 869 of 874,
// hit nothing, and a tap on either did nothing. Item 7 of that page, scrolled
// under the status bar, and a web view's top button under it, hit an element
// the dump did not reach; a tap on either landed on the status bar's
// back-to-app button and switched apps.
func occluded(_ hit: CentreHit, onPage: Bool) -> Bool {
    switch hit {
    case .element: return false
    case .other: return true
    case .nothing, .unplaced: return onPage
    }
}
