import MemosCore
import UIKit

@testable import MemosFeatures

/// The Library's scope toolbar as UIKit drew it (MEMNG-604): the segmented control SwiftUI built
/// for Years | Months | All, found by its segment titles anywhere in the window and judged on
/// screen the way a person sees it — nothing up its superview chain hidden, and some of it inside
/// the window — and the presses that reach it and leave it, made through the controls UIKit built.
@MainActor
enum ScopeBarProbe {
    static let titles = LibraryScope.allCases.map(\.label)

    /// The scope control on screen, or nil when none is.
    static func control(in window: UIWindow) -> UISegmentedControl? {
        var stack: [UIView] = [window]
        while let view = stack.popLast() {
            if let control = view as? UISegmentedControl, segments(of: control) == titles,
                isOnScreen(control, in: window)
            {
                return control
            }
            stack.append(contentsOf: view.subviews)
        }
        return nil
    }

    /// The scope control once it has stopped being replaced: the same object on screen for ten
    /// settles running. A reference taken the moment the control first appears can be one the
    /// toolbar has already rebuilt, and a choice sent to that one reaches no binding (MEMNG-604,
    /// second run) — a person cannot tap a control that is no longer on screen.
    static func settledControl(
        in window: UIWindow, settle: () async -> Void
    ) async -> UISegmentedControl? {
        var last: UISegmentedControl?
        var steady = 0
        for _ in 0..<300 {
            await settle()
            let now = control(in: window)
            steady = now != nil && now === last ? steady + 1 : 0
            last = now
            if steady >= 10 { break }
        }
        return last
    }

    /// Chooses `scope` the way a person can: the segment reading its name is activated as
    /// VoiceOver activates it, and then the index is set and the control's events sent, the way a
    /// tap ends. Setting the index and sending `.valueChanged` alone moved the control and not the
    /// SwiftUI binding behind it (MEMNG-604, first run), so neither path is trusted alone; a second
    /// delivery of the same choice changes nothing (`LibraryScopeChoice.choose`).
    static func choose(_ scope: LibraryScope, in control: UISegmentedControl) {
        guard let index = titles.firstIndex(of: scope.label) else { return }
        var stack: [Any] = [control]
        while let node = stack.popLast() {
            guard let object = node as? NSObject else { continue }
            if object !== control, object.accessibilityLabel == scope.label {
                _ = object.accessibilityActivate()
                break
            }
            stack.append(contentsOf: object.accessibilityElements ?? [])
            if let view = object as? UIView { stack.append(contentsOf: view.subviews) }
        }
        control.selectedSegmentIndex = index
        control.sendActions(for: .valueChanged)
        control.sendActions(for: .primaryActionTriggered)
    }

    /// The title of the segment the control shows chosen.
    static func chosen(in control: UISegmentedControl) -> String? {
        let index = control.selectedSegmentIndex
        guard index >= 0, index < control.numberOfSegments else { return nil }
        return control.titleForSegment(at: index)
    }

    /// Presses `tab`'s item in the app's bar (`LeadingMainBar`, MEMNG-690), the button reading its
    /// name in the window's foot — never the scope row's Library icon, which reads "Library" too
    /// and is a different press. False when no such item is on screen: a folded capsule shows
    /// the selected tab alone, and the scope row shows none, as a person finds them.
    static func pressTab(_ tab: MainTab, in window: UIWindow) -> Bool {
        let foot = window.bounds.height * 0.8
        var stack: [Any] = [window]
        var items: [NSObject] = []
        while let node = stack.popLast() {
            guard let object = node as? NSObject, !(object is UITabBar) else { continue }
            if let view = object as? UIView, view.isHidden || view.alpha < 0.01 { continue }
            if object.accessibilityLabel == tab.title,
                identifier(of: object) != MediaLibraryView.tabsButton,
                windowFrame(of: object, in: window).minY >= foot
            {
                items.append(object)
            }
            stack.append(contentsOf: object.accessibilityElements ?? [])
            if let view = object as? UIView { stack.append(contentsOf: view.subviews) }
        }
        return items.contains { $0.accessibilityActivate() }
    }

    /// Moves to `tab` through the controller UIKit keeps under the hidden bar: no press of the
    /// app's bar, the move a jump to a memo makes from wherever the bar stands — the scope row
    /// included, which offers no other tab to a person (MEMNG-690).
    static func moveTo(_ tab: MainTab, in window: UIWindow) -> Bool {
        guard
            let controller = tabController(in: window.rootViewController),
            let index = controller.tabBar.items?.firstIndex(where: { $0.title == tab.title }),
            let controllers = controller.viewControllers,
            controllers.indices.contains(index)
        else { return false }
        let target = controllers[index]
        let delegate = controller.delegate
        guard delegate?.tabBarController?(controller, shouldSelect: target) ?? true else {
            return false
        }
        controller.selectedViewController = target
        delegate?.tabBarController?(controller, didSelect: target)
        return true
    }

    /// Where the app's tabs are drawn — its capsule, or the capsule folded to the selected tab's
    /// icon — in the window's coordinates; nil when they are not on screen (MEMNG-690).
    static func tabsFrame(in window: UIWindow) -> CGRect? {
        let wanted = [LeadingMainBar.identifier(of: .tabs), LeadingMainBar.identifier(of: .folded)]
        var stack: [Any] = [window]
        while let node = stack.popLast() {
            guard let object = node as? NSObject, !(object is UITabBar) else { continue }
            if let view = object as? UIView, view.isHidden || view.alpha < 0.01 { continue }
            if let named = identifier(of: object), wanted.contains(named) {
                let frame = windowFrame(of: object, in: window)
                if !frame.isEmpty, frame.intersects(window.bounds) { return frame }
            }
            stack.append(contentsOf: object.accessibilityElements ?? [])
            if let view = object as? UIView { stack.append(contentsOf: view.subviews) }
        }
        return nil
    }

    /// The tab titles the app's capsule shows, in the order they are drawn, left to right: each an
    /// element reading a tab's name with its middle inside the capsule (`tabsFrame`), the scope
    /// row's Library icon excepted. A title found at two places is one item drawn twice and is
    /// measured at the leftmost. Empty when the capsule is not on screen.
    static func tabTitlesLeftToRight(in window: UIWindow) -> [String] {
        guard let capsule = tabsFrame(in: window) else { return [] }
        let titles = MainTab.allCases.map(\.title)
        var drawnAt: [String: CGFloat] = [:]
        var stack: [Any] = [window]
        while let node = stack.popLast() {
            guard let object = node as? NSObject, !(object is UITabBar) else { continue }
            if let view = object as? UIView, view.isHidden || view.alpha < 0.01 { continue }
            if let label = object.accessibilityLabel, titles.contains(label),
                identifier(of: object) != MediaLibraryView.tabsButton
            {
                let frame = windowFrame(of: object, in: window)
                if !frame.isEmpty, capsule.contains(CGPoint(x: frame.midX, y: frame.midY)) {
                    drawnAt[label] = min(drawnAt[label] ?? .infinity, frame.midX)
                }
            }
            stack.append(contentsOf: object.accessibilityElements ?? [])
            if let view = object as? UIView { stack.append(contentsOf: view.subviews) }
        }
        return drawnAt.keys.sorted { (drawnAt[$0] ?? 0) < (drawnAt[$1] ?? 0) }
    }

    /// The tab the `TabView` has selected, read off the controller UIKit built for it: its own
    /// bar is never drawn, but it still holds the selection.
    static func selectedTitle(in window: UIWindow) -> String? {
        tabController(in: window.rootViewController)?.tabBar.selectedItem?.title
    }

    /// Whether the app's tabs stand at the foot of the window (`tabsFrame`).
    static func tabsShow(in window: UIWindow) -> Bool {
        tabsFrame(in: window) != nil
    }

    /// Whether UIKit's own tab bar is on screen: it never is, the app's bar being the only one
    /// (MEMNG-690) — SwiftUI keeps the hidden bar in the hierarchy, so on screen is the test.
    static func systemTabBarShows(in window: UIWindow) -> Bool {
        var stack: [UIView] = [window]
        while let view = stack.popLast() {
            if let bar = view as? UITabBar, isOnScreen(bar, in: window) { return true }
            stack.append(contentsOf: view.subviews)
        }
        return false
    }

    /// Presses the scope toolbar's Library icon through what UIKit built for it: the bar button
    /// item's own action when a shown navigation toolbar holds one, else the control or element
    /// drawn for it at the foot of the window. iOS 26 draws a navigation toolbar's items outside
    /// any `UIToolbar` view (MEMNG-604, first run: the control stood in no toolbar), so the items
    /// are read off the navigation controller. Answers how it was pressed, or nil when no such
    /// icon is on screen.
    static func pressLibraryIcon(in window: UIWindow) -> String? {
        for item in shownToolbarItems(in: window) where isLibraryIcon(item) {
            if let action = item.primaryAction {
                action.performWithSender(item, target: nil)
                return "the toolbar item's primary action"
            }
            if let selector = item.action {
                _ = UIApplication.shared.sendAction(
                    selector, to: item.target, from: item, for: nil)
                return "the toolbar item's target and action"
            }
            if let hosted = item.customView, let how = activate(within: hosted) {
                return "the toolbar item's custom view: \(how)"
            }
        }
        // Since build 39 the icon is the app's row (MEMNG-690), and two accessibility nodes stand
        // at its place: the button is pressed first — its identifier, then its button trait, then
        // the smallest frame — so the press is never an activation of a node around it.
        let icons = drawnIcons(in: window).map { element in
            let named = identifier(of: element) == MediaLibraryView.tabsButton
            let button = element.accessibilityTraits.contains(.button)
            let frame = windowFrame(of: element, in: window)
            return (
                element: element, rank: (named ? 0 : 2) + (button ? 0 : 1),
                area: frame.width * frame.height
            )
        }
        let ordered = icons.sorted { ($0.rank, $0.area) < ($1.rank, $1.area) }.map(\.element)
        for element in ordered {
            if let control = element as? UIControl {
                control.sendActions(for: .touchUpInside)
                return "the drawn \(type(of: control))'s touch-up"
            }
            if element.accessibilityActivate() {
                return "the drawn \(type(of: element))'s accessibility activation"
            }
        }
        return nil
    }

    /// Whether UIKit draws a bottom toolbar of its own: a shown navigation toolbar with items, or
    /// a `UIToolbar` view on screen. Since build 39 the scope row is the app's glass under both
    /// styles (MEMNG-690), so the Library leaves UIKit no toolbar to draw.
    static func systemToolbarShows(in window: UIWindow) -> Bool {
        if !shownToolbarItems(in: window).isEmpty { return true }
        var stack: [UIView] = [window]
        while let view = stack.popLast() {
            if let toolbar = view as? UIToolbar, isOnScreen(toolbar, in: window) { return true }
            stack.append(contentsOf: view.subviews)
        }
        return false
    }

    /// Whether the scope toolbar's Library icon is on screen, by the same readings the press uses.
    static func libraryIconShows(in window: UIWindow) -> Bool {
        shownToolbarItems(in: window).contains(where: { isLibraryIcon($0) })
            || !drawnIcons(in: window).isEmpty
    }

    /// Where the scope toolbar's Library icon is drawn, in the window's coordinates (MEMNG-680):
    /// the widest of what the press finds for it, so the glass around the glyph rather than the
    /// glyph alone. An accessibility element's frame is in screen coordinates and is converted, so
    /// every frame a probe compares stands in one space. Nil when no icon is drawn.
    static func libraryIconFrame(in window: UIWindow) -> CGRect? {
        drawnIcons(in: window)
            .map { windowFrame(of: $0, in: window) }
            .filter { !$0.isEmpty }
            .max { $0.width < $1.width }
    }

    /// Every frame drawn for the Library icon, in the window's coordinates, for a message.
    static func libraryIconFrames(in window: UIWindow) -> [CGRect] {
        drawnIcons(in: window).map { windowFrame(of: $0, in: window) }
    }

    /// The segment titles UIKit laid out inside `control` and shows, each with the width its text
    /// needs in its own font on one line and the width it was given. A label given less than its
    /// text needs is drawn truncated, or shrunk to fit.
    static func segmentLabels(
        of control: UISegmentedControl, in window: UIWindow
    ) -> [(text: String, needs: CGFloat, has: CGFloat)] {
        var found: [(text: String, needs: CGFloat, has: CGFloat)] = []
        var stack: [UIView] = [control]
        while let view = stack.popLast() {
            if let label = view as? UILabel, let text = label.text, titles.contains(text),
                isOnScreen(label, in: window)
            {
                let unbounded = CGRect(
                    x: 0, y: 0, width: CGFloat.greatestFiniteMagnitude,
                    height: CGFloat.greatestFiniteMagnitude)
                let needs = label.textRect(forBounds: unbounded, limitedToNumberOfLines: 1).width
                found.append((text: text, needs: needs, has: label.bounds.width))
            }
            stack.append(contentsOf: view.subviews)
        }
        return found
    }

    private static func windowFrame(of object: NSObject, in window: UIWindow) -> CGRect {
        if let view = object as? UIView, view.window != nil {
            return view.convert(view.bounds, to: window)
        }
        // A window without a scene stands at the screen's origin: the two spaces are one.
        guard let screen = window.windowScene?.screen else { return object.accessibilityFrame }
        return screen.coordinateSpace.convert(object.accessibilityFrame, to: window)
    }

    /// The window's bottom chrome as UIKit holds it, for a message and an attachment: each shown
    /// navigation toolbar's items, what is drawn for the Library icon, the tab controller's
    /// accessory, and every segmented control with where it stands.
    static func describe(_ window: UIWindow) -> String {
        var found: [String] = []
        for navigation in navigationControllers(in: window.rootViewController) {
            let items =
                (navigation.topViewController?.toolbarItems ?? [])
                + (navigation.toolbar.items ?? [])
            let read = items.map { item in
                let custom = item.customView.map { " custom=\(type(of: $0))" } ?? ""
                let label = item.accessibilityLabel ?? item.title ?? "-"
                let id = item.accessibilityIdentifier ?? "-"
                let acts =
                    item.primaryAction != nil ? " primary" : item.action != nil ? " target" : ""
                return "[\(label) id=\(id) image=\(item.image != nil)\(acts)\(custom)]"
            }
            found.append(
                "\(type(of: navigation)) toolbarHidden=\(navigation.isToolbarHidden) \(read)")
        }
        let icons = drawnIcons(in: window).map { element in
            let frame =
                (element as? UIView).map { $0.convert($0.bounds, to: window) }
                ?? element.accessibilityFrame
            return "\(type(of: element))@\(Int(frame.minX)),\(Int(frame.minY))"
        }
        found.append("drawn icons: \(icons)")
        var stack: [UIView] = [window]
        while let view = stack.popLast() {
            if let control = view as? UISegmentedControl {
                let frame = control.convert(control.bounds, to: window)
                let shown = isOnScreen(control, in: window) ? "shown" : "hidden"
                found.append(
                    "\(segments(of: control))@\(Int(frame.minX)),\(Int(frame.minY))"
                        + " w\(Int(frame.width)) \(shown)")
            }
            stack.append(contentsOf: view.subviews)
        }
        let controller = tabController(in: window.rootViewController)
        let accessory = controller?.bottomAccessory == nil ? "no accessory" : "an accessory"
        return "\(accessory); chrome: \(found)"
    }

    /// Presses the first control, or else the first element that activates, inside a view SwiftUI
    /// hosts a toolbar item in; answers how, or nil when nothing there answered.
    private static func activate(within hosted: UIView) -> String? {
        var stack: [Any] = [hosted]
        var elements: [NSObject] = []
        while let node = stack.popLast() {
            guard let object = node as? NSObject else { continue }
            if let control = object as? UIControl {
                control.sendActions(for: .touchUpInside)
                return "\(type(of: control))'s touch-up"
            }
            if object !== hosted, object.isAccessibilityElement { elements.append(object) }
            stack.append(contentsOf: object.accessibilityElements ?? [])
            if let view = object as? UIView { stack.append(contentsOf: view.subviews) }
        }
        for element in elements where element.accessibilityActivate() {
            return "\(type(of: element))'s accessibility activation"
        }
        return nil
    }

    /// The items of every navigation toolbar that is shown and whose stack is on screen.
    private static func shownToolbarItems(in window: UIWindow) -> [UIBarButtonItem] {
        navigationControllers(in: window.rootViewController).flatMap { navigation in
            guard !navigation.isToolbarHidden, navigation.viewIfLoaded?.window === window,
                isOnScreen(navigation.view, in: window)
            else { return [UIBarButtonItem]() }
            return (navigation.topViewController?.toolbarItems ?? [])
                + (navigation.toolbar.items ?? [])
        }
    }

    /// What is drawn for the scope row's Library icon: a view or an accessibility element carrying
    /// the button's identifier. Not a label reading "Library" in the foot: the app's capsule has
    /// a Library item there too (MEMNG-690), and it is a tab, not the icon.
    private static func drawnIcons(in window: UIWindow) -> [NSObject] {
        var found: [NSObject] = []
        var stack: [Any] = [window]
        while let node = stack.popLast() {
            guard let object = node as? NSObject, !(object is UITabBar) else { continue }
            if let view = object as? UIView, view.isHidden || view.alpha < 0.01 { continue }
            let frame =
                (object as? UIView).map { $0.convert($0.bounds, to: window) }
                ?? object.accessibilityFrame
            let named = identifier(of: object) == MediaLibraryView.tabsButton
            if named, !frame.isEmpty { found.append(object) }
            stack.append(contentsOf: object.accessibilityElements ?? [])
            if let view = object as? UIView { stack.append(contentsOf: view.subviews) }
        }
        return found
    }

    static func tabController(in controller: UIViewController?) -> UITabBarController? {
        guard let controller else { return nil }
        if let found = controller as? UITabBarController { return found }
        for child in controller.children {
            if let found = tabController(in: child) { return found }
        }
        return tabController(in: controller.presentedViewController)
    }

    private static func identifier(of object: NSObject) -> String? {
        if let named = object as? UIAccessibilityIdentification {
            return named.accessibilityIdentifier
        }
        // SwiftUI's accessibility nodes answer the selector without declaring the protocol, as
        // the leading bar's glass markers are found (`mainGlass`).
        guard object.responds(to: Selector(("accessibilityIdentifier"))) else { return nil }
        return object.value(forKey: "accessibilityIdentifier") as? String
    }

    private static func isLibraryIcon(_ item: UIBarButtonItem) -> Bool {
        item.accessibilityIdentifier == MediaLibraryView.tabsButton
            || item.accessibilityLabel == MainTab.library.title
            || item.title == MainTab.library.title
    }

    private static func navigationControllers(
        in controller: UIViewController?
    ) -> [UINavigationController] {
        guard let controller else { return [] }
        var found: [UINavigationController] = []
        if let navigation = controller as? UINavigationController { found.append(navigation) }
        for child in controller.children {
            found += navigationControllers(in: child)
        }
        return found
    }

    private static func segments(of control: UISegmentedControl) -> [String] {
        (0..<control.numberOfSegments).map { control.titleForSegment(at: $0) ?? "" }
    }

    private static func isOnScreen(_ view: UIView, in window: UIWindow) -> Bool {
        var node: UIView? = view
        while let current = node {
            if current.isHidden || current.alpha < 0.01 { return false }
            node = current.superview
        }
        let frame = view.convert(view.bounds, to: window)
        return !frame.isEmpty && frame.intersects(window.bounds)
    }
}
