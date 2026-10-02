import MemosCore
import UIKit

@testable import MemosFeatures

/// The Library's Years | Months | All as UIKit drew it (MEMNG-604): the segmented control SwiftUI
/// built for the `Picker`, found by its segment titles anywhere in the window — the tab bar's
/// subtree included, since the accessory is the bar's — and judged on screen the way a person
/// sees it: nothing up its superview chain hidden, and some of it inside the window.
@MainActor
enum ScopeAccessoryProbe {
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
    /// accessory has already rehosted, and a choice sent to that one reaches no binding
    /// (MEMNG-604, second run) — a person cannot tap a control that is no longer on screen.
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

    /// Whether `view` stands inside the content view of the bottom accessory UIKit's tab
    /// controller carries — the slot `.tabViewBottomAccessory` fills — rather than anywhere else.
    static func isInAccessory(_ view: UIView, window: UIWindow) -> Bool {
        let controller = tabController(in: window.rootViewController)
        guard let content = controller?.bottomAccessory?.contentView else { return false }
        return view.isDescendant(of: content)
    }

    /// Where the system reports the accessory laid out: above the bar, or inline beside it.
    static func placement(of view: UIView) -> UITabAccessory.Environment {
        view.traitCollection[UITraitTabAccessoryEnvironment.self]
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

    /// What the window holds in the way of segmented controls and an accessory, for a message.
    static func describe(_ window: UIWindow) -> String {
        var found: [String] = []
        var stack: [UIView] = [window]
        while let view = stack.popLast() {
            if let control = view as? UISegmentedControl {
                let frame = control.convert(control.bounds, to: window)
                let shown = isOnScreen(control, in: window) ? "shown" : "hidden"
                let targets = control.allTargets.count
                found.append("\(segments(of: control))@\(Int(frame.minY)) \(shown) t\(targets)")
            }
            stack.append(contentsOf: view.subviews)
        }
        let controller = tabController(in: window.rootViewController)
        let accessory = controller?.bottomAccessory == nil ? "no accessory" : "an accessory"
        return "\(accessory); segmented controls: \(found)"
    }

    static func tabController(in controller: UIViewController?) -> UITabBarController? {
        guard let controller else { return nil }
        if let found = controller as? UITabBarController { return found }
        for child in controller.children {
            if let found = tabController(in: child) { return found }
        }
        return tabController(in: controller.presentedViewController)
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
