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
