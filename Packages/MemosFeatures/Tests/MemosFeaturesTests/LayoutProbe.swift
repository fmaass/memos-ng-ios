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
