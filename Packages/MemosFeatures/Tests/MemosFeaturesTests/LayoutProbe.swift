import Foundation
import MemosCore
import SwiftUI
import UIKit

@testable import MemosFeatures

/// Measuring what SwiftUI actually lays out, so "it fits" is an assertion rather than an opinion.
///
/// A hosting controller is the only honest way to ask a SwiftUI view how big it wants to be. The
/// tests that use it are the ones that would otherwise be a screenshot somebody looks at once.
@MainActor
enum LayoutProbe {
    /// A width no view will ever want more than, standing in for an unbounded proposal.
    /// `.greatestFiniteMagnitude` makes some SwiftUI containers return nonsense.
    static let unbounded: CGFloat = 10_000

    static func size(
        _ view: some View,
        width: CGFloat,
        typeSize: DynamicTypeSize
    ) -> CGSize {
        let host = UIHostingController(rootView: view.environment(\.dynamicTypeSize, typeSize))
        return host.sizeThatFits(in: CGSize(width: width, height: unbounded))
    }

    /// The size a view reports for an explicit proposal, with the type size left alone. Used to
    /// hold every layer of a tile to the slot it was offered.
    static func size(_ view: some View, width: CGFloat, height: CGFloat) -> CGSize {
        UIHostingController(rootView: view)
            .sizeThatFits(in: CGSize(width: width, height: height))
    }

    /// What the view WANTS, with nothing squeezing it — the width below which it must start
    /// truncating.
    static func idealWidth(_ view: some View, typeSize: DynamicTypeSize) -> CGFloat {
        size(view, width: unbounded, typeSize: typeSize).width
    }

    /// How tall this text is at this size in this width, measured by UIKit rather than by us.
    static func textHeight(
        _ text: String,
        style: UIFont.TextStyle,
        category: UIContentSizeCategory,
        width: CGFloat
    ) -> CGFloat {
        let font = UIFont.preferredFont(
            forTextStyle: style,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: category)
        )
        return (text as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font],
            context: nil
        ).height
    }
}

/// Rendering a view and reading a pixel back out of it. Used for exactly one thing: proving that
/// a thumbnail whose image has not arrived is painted with the picture's own colours.
@MainActor
enum PixelProbe {
    static func centre(of view: some View, size: CGSize) -> (r: UInt8, g: UInt8, b: UInt8)? {
        let renderer = ImageRenderer(
            content: view.frame(width: size.width, height: size.height)
        )
        renderer.scale = 1
        guard let cgImage = renderer.cgImage else { return nil }
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else {
            return nil
        }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard
                let context = CGContext(
                    data: buffer.baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width * 4,
                    space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )
            else { return false }
            context.draw(
                cgImage,
                in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
            )
            return true
        }
        guard drawn else { return nil }
        let offset = ((height / 2) * width + (width / 2)) * 4
        return (bytes[offset], bytes[offset + 1], bytes[offset + 2])
    }

    /// The same reading, taken off a view that is really on a screen.
    ///
    /// `ImageRenderer` draws a `ScrollView` as nothing whatsoever, so a row that scrolls reads as
    /// an empty tile however well it paints — and a row of pictures is exactly the thing worth
    /// asserting. The capture follows the one the loader's suite takes: the run loop is given a
    /// turn before the hierarchy is drawn, because what a state change queued has not been
    /// committed yet.
    static func centreOnScreen(
        of view: some View,
        size: CGSize
    ) -> (r: UInt8, g: UInt8, b: UInt8)? {
        let host = UIHostingController(
            rootView: view.frame(width: size.width, height: size.height)
        )
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = host
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(bounds: host.view.bounds, format: format)
        let shot = renderer.image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        window.isHidden = true
        window.rootViewController = nil
        guard let cgImage = shot.cgImage else { return nil }
        return centre(of: cgImage)
    }

    /// The middle pixel of a drawn image, in sRGB.
    private static func centre(of cgImage: CGImage) -> (r: UInt8, g: UInt8, b: UInt8)? {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else {
            return nil
        }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard
                let context = CGContext(
                    data: buffer.baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width * 4,
                    space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )
            else { return false }
            context.draw(
                cgImage,
                in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
            )
            return true
        }
        guard drawn else { return nil }
        let offset = ((height / 2) * width + (width / 2)) * 4
        return (bytes[offset], bytes[offset + 1], bytes[offset + 2])
    }
}

/// A flat image of a known colour, for asserting which layer of a tile ended up where.
@MainActor
enum SolidImage {
    static func of(_ color: UIColor, side: CGFloat = 8) -> Image {
        of(color, size: CGSize(width: side, height: side))
    }

    static func of(_ color: UIColor, size: CGSize) -> Image {
        let renderer = UIGraphicsImageRenderer(size: size)
        return Image(
            uiImage: renderer.image { context in
                color.setFill()
                context.fill(CGRect(origin: .zero, size: size))
            }
        )
    }
}

/// Every pixel of a rendered view, so a test can ask which layer covered what.
@MainActor
enum PixelGrid {
    static func of(_ view: some View, size: CGSize) -> [[(r: UInt8, g: UInt8, b: UInt8)]]? {
        let renderer = ImageRenderer(
            content: view.frame(width: size.width, height: size.height)
        )
        renderer.scale = 1
        guard let cgImage = renderer.cgImage, let space = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            guard
                let context = CGContext(
                    data: buffer.baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width * 4,
                    space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )
            else { return }
            context.draw(
                cgImage,
                in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
            )
        }
        return (0..<height).map { y in
            (0..<width).map { x in
                let offset = (y * width + x) * 4
                return (bytes[offset], bytes[offset + 1], bytes[offset + 2])
            }
        }
    }
}

/// One value written by a view's own callback and read by the assertion afterwards.
///
/// No lock: everything in this bundle is on the main actor, which is also where SwiftUI calls back.
@MainActor
final class Box<Value> {
    var value: Value

    init(_ value: Value) { self.value = value }
}

/// A memo built for a test, with only the fields the assertion cares about spelled out.
@MainActor
enum MemoFixture {
    static func memo(
        uid: String = "m1",
        owner: String = "fabian@example.invalid",
        content: String = "A memo.",
        mine: Bool = true,
        visibility: MemoVisibility = .protected,
        pinned: Bool = false,
        createdAt: Date = Date(timeIntervalSince1970: 1_750_000_000),
        archivedAt: Date? = nil,
        tags: [String] = [],
        attachments: [MemoAttachment] = []
    ) -> Memo {
        Memo(
            uid: uid,
            owner: owner,
            mine: mine,
            content: content,
            visibility: visibility,
            pinned: pinned,
            createdAt: createdAt,
            updatedAt: createdAt,
            archivedAt: archivedAt,
            tags: tags,
            attachments: attachments
        )
    }

    static func attachment(blurhash: String?) -> MemoAttachment {
        MemoAttachment(
            uid: "a1",
            mime: "image/jpeg",
            status: .ready,
            blurhash: blurhash,
            width: 1000,
            height: 1000,
            thumbnailURL: URL(string: "https://memos.example.invalid/thumb")
        )
    }
}

/// Hosting a screen and then handing it a different set of inputs.
///
/// What a view does when what it was given CHANGES is a behaviour of its own, and a probe that
/// renders one state and takes the window down again can never ask for it: the change modifiers
/// fire on an update, and a screen that only ever existed once was never updated.
@MainActor
enum RedrawProbe {
    static func host<V: View>(_ first: V, then second: V) {
        let host = UIHostingController(rootView: first)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = host
        window.isHidden = false

        settle(host, in: window)
        host.rootView = second
        settle(host, in: window)

        window.isHidden = true
        window.rootViewController = nil
    }

    private static func settle(_ host: UIViewController, in window: UIWindow) {
        for _ in 0..<50 {
            window.layoutIfNeeded()
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            RunLoop.current.run(mode: .default, before: Date())
        }
    }
}

/// Hosting a view on a real screen and pressing a control in it, by the label VoiceOver reads.
///
/// Separate from `ScreenProbe` because that one spins the run loop for four tenths of a second: a
/// toolbar item arrives on a later turn than the first layout, so a screen with one has to be
/// waited for. What this presses has none. It lays out, looks, and drains only what is ALREADY ready,
/// giving up the moment the element exists — so it is over as soon as the row is there rather than
/// after a fixed time.
///
/// The element is handed to the caller while the window is still up: activating a button whose
/// window has already been torn down does nothing at all, which would look exactly like a wiring
/// that was never connected.
@MainActor
enum PressProbe {
    /// The window is a phone's width and, by default, a short one: a control that has to be
    /// scrolled to is a control most people will not find. A screen that legitimately stacks
    /// panels above the one being pressed asks for a taller one rather than being tested against
    /// a viewport it could never fit in.
    static func withElement<T>(
        labelled label: String,
        in view: some View,
        height: CGFloat = 200,
        _ body: (NSObject?) -> T
    ) -> T {
        let host = UIHostingController(rootView: view)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: height))
        window.rootViewController = host
        window.isHidden = false

        var found: NSObject?
        for _ in 0..<50 {
            window.layoutIfNeeded()
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            found = element(labelled: label, in: window)
            if found != nil { break }
            RunLoop.current.run(mode: .default, before: Date())
        }

        let result = body(found)
        window.isHidden = true
        window.rootViewController = nil
        return result
    }

    /// One window, pressed more than once, with what the presses START allowed to run in between.
    ///
    /// Hosting a screen twice is two screens: the second is a fresh view with its own state, in
    /// which nothing the first one started is running. So what a screen refuses WHILE one of its
    /// own operations is in flight can only be asked inside a single window.
    ///
    /// The body is ASYNC for the other half of the same reason. What a press starts is a task on
    /// this actor, and a body that never suspends never lets it run — however long it spins the
    /// run loop, because the actor it is waiting for is the one it is holding.
    static func withScreen<T>(
        _ view: some View,
        height: CGFloat = 200,
        _ body: (Screen) async -> T
    ) async -> T {
        let host = UIHostingController(rootView: view)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: height))
        window.rootViewController = host
        window.isHidden = false

        let result = await body(Screen(host: host, window: window))
        window.isHidden = true
        window.rootViewController = nil
        return result
    }

    /// A window that is still up: what is on it, and what pressing it starts.
    @MainActor
    struct Screen {
        let host: UIViewController
        let window: UIWindow

        /// The control by the label VoiceOver reads.
        ///
        /// A deadline rather than a fixed number of turns, because this one can be asked for a
        /// TOOLBAR item, which SwiftUI installs on a later turn of the run loop than the first
        /// layout — and it gives up the moment the element exists, so a control that is already
        /// there costs nothing to find.
        func element(labelled label: String) -> NSObject? {
            let deadline = Date().addingTimeInterval(0.4)
            repeat {
                layOut()
                if let found = PressProbe.element(labelled: label, in: window) { return found }
                RunLoop.current.run(until: Date().addingTimeInterval(slice))
            } while Date() < deadline
            return nil
        }

        /// Presses it, and says whether there was anything there that took the press.
        func press(_ label: String) -> Bool {
            element(labelled: label)?.accessibilityActivate() ?? false
        }

        /// Presses the segment titled `title` of a segmented control on the window, and says
        /// whether an enabled control had that segment to press.
        ///
        /// `press` cannot reach one: its walk takes only a node that reads the label AND carries
        /// the button trait, and a segment of the `UISegmentedControl` SwiftUI draws for a
        /// segmented `Picker` is not such a node in a test host. So the segment reading its title
        /// is activated as VoiceOver would, and when that left the control where it was, the
        /// segment is chosen and the control's events sent, the way a tap on it ends — the same
        /// two paths `ScopeBarProbe.choose` takes on the Library's scope control, the second only
        /// when the first did nothing, so one press is one choice. A segment already chosen is no
        /// press: a tap there changes nothing.
        func pressSegment(_ title: String) -> Bool {
            let deadline = Date().addingTimeInterval(0.4)
            repeat {
                layOut()
                if case let (control, index)? = PressProbe.segment(titled: title, in: window) {
                    guard control.isEnabled, control.selectedSegmentIndex != index else {
                        return false
                    }
                    _ = PressProbe.segmentElement(titled: title, in: control)?
                        .accessibilityActivate()
                    if control.selectedSegmentIndex != index {
                        control.selectedSegmentIndex = index
                        control.sendActions(for: .valueChanged)
                        control.sendActions(for: .primaryActionTriggered)
                    }
                    return true
                }
                RunLoop.current.run(until: Date().addingTimeInterval(slice))
            } while Date() < deadline
            return false
        }

        /// The titles of every segmented control on the window, for a message that has to say
        /// what was there when a segment was not.
        var segmentTitles: [[String]] {
            PressProbe.segmentedControls(in: window).map { control in
                (0..<control.numberOfSegments).map { control.titleForSegment(at: $0) ?? "?" }
            }
        }

        /// Whether the control is there and would take a press now: the same element `press`
        /// finds, not marked `.notEnabled`. What a press started can still be holding a control
        /// disabled after the effect a test waits for has landed, so the next press waits on this.
        func isLive(_ label: String) -> Bool {
            guard let found = element(labelled: label) else { return false }
            return !found.accessibilityTraits.contains(.notEnabled)
        }

        /// Whether anything on the screen READS as this sentence.
        ///
        /// A line of text carries no button trait, so it is not a control and `element(labelled:)`
        /// will not find it. This is the other half: what the screen SAYS, which for a sentence
        /// somebody has to act on is the part that matters.
        func says(_ sentence: String) -> Bool {
            layOut()
            return PressProbe.reads(sentence, in: window)
        }

        /// Gives the screen its turns: what a press started runs, and what it writes comes back
        /// round to the layout. Each turn SUSPENDS — the task the press made is isolated to this
        /// actor, so it runs only while the caller is not holding it, and no amount of spinning a
        /// run loop will do instead. It gives up the moment the caller has what it waited for.
        func settle(turns: Int = 20, until ready: () -> Bool = { false }) async {
            for _ in 0..<turns {
                if ready() { return }
                layOut()
                await Task.yield()
                try? await Task.sleep(for: .milliseconds(1))
            }
        }

        /// How long one turn gives the run loop. `run(until:)` rather than draining what is merely
        /// ready: a toolbar item is installed on a turn of its own.
        private var slice: TimeInterval { 0.01 }

        private func layOut() {
            window.layoutIfNeeded()
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
        }
    }

    /// Walks the same hierarchy `element(labelled:)` does, asking what each node says rather than
    /// whether it can be pressed.
    static func reads(_ sentence: String, in node: Any) -> Bool {
        guard let object = node as? NSObject else { return false }
        if let label = object.accessibilityLabel, label.contains(sentence) { return true }
        if let value = object.accessibilityValue, value.contains(sentence) { return true }
        for child in object.accessibilityElements ?? [] where reads(sentence, in: child) {
            return true
        }
        if let view = object as? UIView {
            for subview in view.subviews where reads(sentence, in: subview) { return true }
        }
        return false
    }

    /// Every segmented control in the window's view tree that is drawn: not hidden, and inside
    /// the window's bounds — a control the window does not show is one nobody can tap.
    static func segmentedControls(in window: UIWindow) -> [UISegmentedControl] {
        var found: [UISegmentedControl] = []
        var stack: [UIView] = [window]
        while let view = stack.popLast() {
            if let control = view as? UISegmentedControl, !control.isHidden,
                control.convert(control.bounds, to: window).intersects(window.bounds)
            {
                found.append(control)
            }
            stack.append(contentsOf: view.subviews)
        }
        return found
    }

    /// The first drawn control with a segment titled `title`, and that segment's index.
    static func segment(titled title: String, in window: UIWindow) -> (UISegmentedControl, Int)? {
        for control in segmentedControls(in: window) {
            for index in 0..<control.numberOfSegments
            where control.titleForSegment(at: index) == title {
                return (control, index)
            }
        }
        return nil
    }

    /// The node under `control` that reads `title`, by its accessibility elements and its views.
    static func segmentElement(titled title: String, in control: UISegmentedControl) -> NSObject? {
        var stack: [Any] = [control]
        while let node = stack.popLast() {
            guard let object = node as? NSObject else { continue }
            if object !== control, object.accessibilityLabel == title { return object }
            stack.append(contentsOf: object.accessibilityElements ?? [])
            if let view = object as? UIView { stack.append(contentsOf: view.subviews) }
        }
        return nil
    }

    private static func element(labelled label: String, in node: Any) -> NSObject? {
        guard let object = node as? NSObject else { return nil }
        if object.accessibilityLabel == label, object.accessibilityTraits.contains(.button) {
            return object
        }
        for child in object.accessibilityElements ?? [] {
            if let found = element(labelled: label, in: child) { return found }
        }
        if let view = object as? UIView {
            for subview in view.subviews {
                if let found = element(labelled: label, in: subview) { return found }
            }
        }
        return nil
    }
}
