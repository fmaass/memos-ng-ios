import Foundation
import MemosCore
import SwiftUI
import Testing
import UIKit

@testable import MemosFeatures

/// Drawing the account menu's rows on a real device, and proving they drew something.
///
/// This repo's habit is that a screenshot is what a test CANNOT check, so the assertion here is
/// the one a picture could not make: that the rows render at all, and that the result is not a
/// blank rectangle. The image itself is emitted for whoever wants to look.
///
/// It renders `AccountMenuRows` — the very view the `Menu` in the toolbar presents. A `UIMenu`
/// popover is presented by the system and nothing in process can render it, so a capture of "the
/// menu open" can only ever be a capture of its contents; sharing the view is what stops that
/// capture from being a picture of a second, hand-written copy of rows the app does not have.
///
/// The SETTINGS SCREEN is deliberately not rendered here, and the reason is structural rather
/// than incidental: `SettingsView` reads `SessionStore` from the environment, and constructing one
/// inlines `APIClientFactory.make` from the API layer — which this bundle does not link, because
/// Features reaches the API through Core and never directly. Making the screen's session optional
/// to get around that would be defensive code written for a test, and adding the API layer to this
/// bundle would be the dependency rule bent for a screenshot. What the screen is made of is held
/// instead by `SettingsScreenTests` (which sections, in what order, and that none is stubbed) and
/// by the suites over every function it draws from.
@MainActor
@Suite("The account menu draws")
struct SettingsRenderTests {
    /// Hosted in a real window and drawn from the hierarchy rather than through `ImageRenderer`:
    /// the rows are UIKit-backed once SwiftUI lays them out, and `ImageRenderer` sees only the
    /// SwiftUI content — which comes back as an empty background, exactly the blank rectangle
    /// `isNotBlank` exists to refuse.
    private func render(_ view: some View, size: CGSize) -> UIImage? {
        let host = UIHostingController(rootView: view)
        host.view.frame = CGRect(origin: .zero, size: size)
        let window = UIWindow(frame: host.view.frame)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        // Scale pinned rather than taken from the device: the gate picks whichever simulator the
        // build host has newest, and a capture whose pixel size depended on that would be a
        // different picture every time the runtime moved. 2x is legible and a quarter the bytes
        // of the 3x a Pro device would otherwise hand back.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let renderer = UIGraphicsImageRenderer(bounds: host.view.bounds, format: format)
        let image = renderer.image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        window.isHidden = true
        return image
    }

    /// More than one colour in the frame. A render that failed politely hands back a single flat
    /// rectangle, which is exactly what a bare "it rendered" check would otherwise accept.
    private func isNotBlank(_ image: UIImage) -> Bool {
        guard let cgImage = image.cgImage,
            let data = cgImage.dataProvider?.data,
            let bytes = CFDataGetBytePtr(data)
        else { return false }
        let count = CFDataGetLength(data)
        guard count > 4 else { return false }
        let first = (bytes[0], bytes[1], bytes[2])
        // A prime stride, so the sampling cannot fall into step with the row width and read the
        // same column of an otherwise varied image over and over.
        for offset in stride(from: 0, to: count - 3, by: 401 * 4)
        where (bytes[offset], bytes[offset + 1], bytes[offset + 2]) != first {
            return true
        }
        return false
    }

    private func capture(_ image: UIImage, named name: String) {
        guard let png = image.pngData() else {
            Issue.record("\(name) produced no PNG data")
            return
        }
        // Emitted as base64 because the gate deletes its per-run simulator on every exit path, so
        // a file written inside the device does not outlive the run, and the result bundle's
        // attachments cannot be read back on the Linux machine this repo is developed on. It is
        // one long line of roughly 50 KB in the gate log; extract it by matching these markers.
        // Kept rather than removed after the capture round: without it there is no way to get the
        // picture again, and a capture path that has to be re-invented is one nobody uses.
        print("MEMOSNG_CAPTURE_BEGIN \(name) \(png.count)")
        print(png.base64EncodedString())
        print("MEMOSNG_CAPTURE_END \(name)")
    }

    private func menu(name: String?) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.regular) {
            AccountMenuRows(
                rows: AccountMenu.rows(name: name),
                openSettings: {},
                signOut: {}
            )
        }
        .padding(DesignTokens.Space.roomy)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: DesignTokens.Radius.card))
        .padding(DesignTokens.Space.roomy)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(.systemGroupedBackground))
    }

    @Test("the account menu's rows draw, in their order")
    func accountMenuRowsRender() throws {
        let size = CGSize(width: 393, height: 260)
        let image = try #require(render(menu(name: "Fabian"), size: size))

        #expect(isNotBlank(image))
        capture(image, named: "account-menu")
    }

    /// The same rows for an account with no name — the heading still has to draw something, and a
    /// menu whose first row collapsed to nothing would put the destructive row back under the
    /// anchor (`AccountMenu`).
    @Test("an unnamed account still draws a heading row")
    func unnamedAccountStillDrawsAHeading() throws {
        let size = CGSize(width: 393, height: 260)
        let image = try #require(render(menu(name: nil), size: size))

        #expect(isNotBlank(image))
    }
}
