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

    /// Presses `tab`'s item through the controller UIKit built for the system bar, the way a tap
    /// on it does — which, on the tab already showing, is a re-selection the `TabView` hears.
    static func pressTab(_ tab: MainTab, in window: UIWindow) -> Bool {
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
        for element in drawnIcons(in: window) {
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

    /// What is drawn for the Library icon in the window's foot, outside the tab bar: a view or an
    /// accessibility element carrying the button's identifier, or reading "Library" there — the
    /// Library's header reads "Library" too, at the top, which is why the foot is the condition.
    private static func drawnIcons(in window: UIWindow) -> [NSObject] {
        var found: [NSObject] = []
        let foot = window.bounds.height * 0.8
        var stack: [Any] = [window]
        while let node = stack.popLast() {
            guard let object = node as? NSObject, !(object is UITabBar) else { continue }
            if let view = object as? UIView, view.isHidden || view.alpha < 0.01 { continue }
            let frame =
                (object as? UIView).map { $0.convert($0.bounds, to: window) }
                ?? object.accessibilityFrame
            let named =
                identifier(of: object) == MediaLibraryView.tabsButton
                || (object.accessibilityLabel == MainTab.library.title && frame.minY >= foot)
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
        (object as? UIAccessibilityIdentification)?.accessibilityIdentifier
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
