import Foundation
import MemosCore
import SwiftUI
import UIKit

@testable import MemosFeatures

/// The `AppDock` a hosted `MainTabs` built, once a tab's screen has appeared: what the double-bar
/// reproductions ask which bar the dock says stands (`AppDock.bar(on:)`), and the dock a reading
/// is handed to when a test has to choose WHEN that reading arrives
/// (`AppDock.scrolled(from:to:judgedBy:moving:at:)`). The dock is `MainTabs`' own state, which
/// nothing outside its tree can reach, so a screen inside it reports it here.
final class DockWitness {
    var dock: AppDock?
}

/// `MainTabView`'s tree, rebuilt so each tab's screen reports the dock to a `DockWitness`: the same
/// `MainTabs`, the same three screens and the same `MemoJump` routing, inside the same stack. The
/// session notice is left out: the fixture's session is signed in and reachable, which draws none.
struct DockWitnessTabs: View {
    let witness: DockWitness
    @State private var selection: MainTab
    @State private var jump = MemoJump()

    init(opening tab: MainTab, witness: DockWitness) {
        self.witness = witness
        _selection = State(initialValue: tab)
    }

    var body: some View {
        VStack(spacing: 0) {
            MainTabs(selection: $selection) { tab in
                screen(for: tab).modifier(DockWitnessing(witness: witness))
            }
            .environment(jump)
            .onChange(of: jump.pending) { _, pending in
                selection = MemoJumpRouting.tab(showing: selection, whenJumping: pending)
            }
        }
    }

    @ViewBuilder
    private func screen(for tab: MainTab) -> some View {
        switch tab {
        case .timeline: TimelineView()
        case .library: MediaLibraryView()
        case .places: PlacesView()
        }
    }
}

/// Hands the dock in the environment to the witness when the screen appears; adds no view.
private struct DockWitnessing: ViewModifier {
    let witness: DockWitness
    @Environment(AppDock.self) private var dock: AppDock?

    func body(content: Content) -> some View {
        content.onAppear { witness.dock = dock }
    }
}

/// A fling of a scroll view, one move per `step()`, told to its delegate as a finger's is: a drag
/// over the first moves, let go with a velocity, then a deceleration whose moves shrink, and its
/// end. Made a move at a time so a test can press Close between two of them and keep the scroll
/// view moving — and its readings arriving — after the press.
final class Fling {
    private let scroller: UIScrollView
    private let offsets: [CGFloat]
    private let letGo: Int
    private(set) var made = 0
    let travel: CGFloat

    /// `distance` from where the scroll view stands, turned the other way when the side it points
    /// to has less than half of it to give; every move kept between `floor` (the top when nil) and
    /// the foot.
    init(
        _ scroller: UIScrollView, by distance: CGFloat, floor: CGFloat? = nil,
        dragMoves: Int = 4, coastMoves: Int = 24
    ) {
        self.scroller = scroller
        let top = -scroller.adjustedContentInset.top
        let inset = scroller.adjustedContentInset.bottom
        let foot = max(top, scroller.contentSize.height - scroller.bounds.height + inset)
        let low = max(top, floor ?? top)
        let from = scroller.contentOffset.y
        let room = distance > 0 ? foot - from : from - low
        let travel = room >= abs(distance) / 2 ? distance : -distance
        self.travel = travel
        let weights = (0..<coastMoves).map { pow(0.85, Double($0)) }
        let total = weights.reduce(0, +)
        var path: [CGFloat] = (1...dragMoves).map {
            from + travel * 0.4 * CGFloat($0) / CGFloat(dragMoves)
        }
        var covered = 0.0
        for weight in weights {
            covered += weight
            path.append(from + travel * (0.4 + 0.6 * CGFloat(covered / total)))
        }
        offsets = path.map { min(max($0, low), foot) }
        letGo = dragMoves - 1
    }

    var count: Int { offsets.count }
    var finished: Bool { made >= offsets.count }

    /// The next move, with what the delegate hears around it; nothing once the fling has ended.
    func step() {
        guard made < offsets.count else { return }
        let delegate = scroller.delegate
        if made == 0 { delegate?.scrollViewWillBeginDragging?(scroller) }
        let x = scroller.contentOffset.x
        scroller.setContentOffset(CGPoint(x: x, y: offsets[made]), animated: false)
        if made == letGo {
            let end = offsets.last ?? offsets[made]
            var target = CGPoint(x: x, y: end)
            let velocity = CGPoint(x: 0, y: end >= offsets[made] ? 2.5 : -2.5)
            delegate?.scrollViewWillEndDragging?(
                scroller, withVelocity: velocity, targetContentOffset: &target)
            delegate?.scrollViewDidEndDragging?(scroller, willDecelerate: true)
            delegate?.scrollViewWillBeginDecelerating?(scroller)
        }
        if made == offsets.count - 1 { delegate?.scrollViewDidEndDecelerating?(scroller) }
        made += 1
    }

    var summary: String {
        let first = offsets.first.map { "\(Int($0))" } ?? "-"
        let last = offsets.last.map { "\(Int($0))" } ?? "-"
        return "fling \(Int(travel)) pt, \(made) of \(offsets.count) moves made, \(first)->\(last)"
    }
}

/// How each bottom bar stood at one sample, for the log of a double-bar reproduction: the tab bar's
/// and every scope control's own hidden flag and alpha, the first view up its chain that hides it,
/// the lowest alpha on that chain, and its frame in the window.
enum DoubleBarProbe {
    static func tabBarDetail(in window: UIWindow) -> String {
        guard let bar = tabBar(in: window) else { return "absent" }
        let frame = bar.convert(bar.bounds, to: window)
        let drawn = drawnExtent(of: bar, in: window)
        return "\(chain(of: bar)) frame=\(text(frame)) drawn=\(text(drawn))"
    }

    /// Every Years | Months | All control in the window, shown or not.
    static func scopeDetail(in window: UIWindow) -> String {
        var found: [String] = []
        var stack: [UIView] = [window]
        while let view = stack.popLast() {
            if let control = view as? UISegmentedControl,
                (0..<control.numberOfSegments).map({ control.titleForSegment(at: $0) ?? "" })
                    == ScopeBarProbe.titles
            {
                let frame = control.convert(control.bounds, to: window)
                found.append("\(chain(of: control)) frame=\(text(frame))")
            }
            stack.append(contentsOf: view.subviews)
        }
        return found.isEmpty ? "absent" : found.joined(separator: " ; ")
    }

    /// The width of what the tab bar draws — its visible leaves' union — which narrows when the
    /// system minimises it to the selected tab; nil when there is no tab bar.
    static func tabBarDrawnWidth(in window: UIWindow) -> CGFloat? {
        tabBar(in: window).map { drawnExtent(of: $0, in: window).width }
    }

    private static func tabBar(in window: UIWindow) -> UITabBar? {
        var stack: [UIView] = [window]
        while let view = stack.popLast() {
            if let bar = view as? UITabBar { return bar }
            stack.append(contentsOf: view.subviews)
        }
        return nil
    }

    private static func drawnExtent(of root: UIView, in window: UIWindow) -> CGRect {
        var extent = CGRect.null
        var stack: [UIView] = [root]
        while let view = stack.popLast() {
            guard !view.isHidden, view.alpha >= 0.01 else { continue }
            let frame = view.convert(view.bounds, to: window)
            if view.subviews.isEmpty, !frame.isEmpty { extent = extent.union(frame) }
            stack.append(contentsOf: view.subviews)
        }
        return extent
    }

    private static func chain(of view: UIView) -> String {
        var hider = "-"
        var lowest = view.alpha
        var node: UIView? = view
        while let current = node {
            if current.isHidden, hider == "-" { hider = "\(type(of: current))" }
            lowest = min(lowest, current.alpha)
            node = current.superview
        }
        return "hidden=\(view.isHidden) alpha=\(text(view.alpha)) hiddenBy=\(hider)"
            + " chainAlpha=\(text(lowest))"
    }

    private static func text(_ value: CGFloat) -> String { String(format: "%.2f", Double(value)) }

    private static func text(_ rect: CGRect) -> String {
        guard !rect.isNull else { return "none" }
        return "\(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))x\(Int(rect.height))"
    }
}
