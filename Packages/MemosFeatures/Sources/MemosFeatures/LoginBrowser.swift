import Foundation
import SafariServices
import UIKit

/// The browser view as the sign-in needs it: something that can be put on screen, taken down, and
/// asked whether it actually made it.
///
/// It is a protocol for one reason, and it is the reason the sign-in was broken for a week: the
/// bugs in this flow are not in any single step but in how the steps INTERLEAVE — a browser view
/// closing after its attempt was cancelled, a watchdog firing into somebody else's sign-in, a
/// second tap arriving mid-flight. None of those can be produced by driving a real
/// `SFSafariViewController`, which cannot be opened, closed or timed from a test at all. Behind
/// this seam every one of them is a few deterministic lines.
@MainActor
protocol LoginBrowser: AnyObject {
    /// Called when the PERSON closed the view. Never called for a dismissal the app asked for.
    var onClose: (() -> Void)? { get set }
    /// Called for each redirect the browser follows while loading.
    var onRedirect: ((URL) -> Void)? { get set }
    /// Called when the first page finished loading, successfully or not.
    var onInitialLoad: ((Bool) -> Void)? { get set }

    func present(from host: UIViewController)
    func dismiss()
    /// Whether the view is on screen. The watchdog's evidence, and the one question the failure
    /// this flow was rebuilt around could never be asked of the system's own presentation.
    var isOnScreen: Bool { get }
}

/// The real one: `SFSafariViewController`, which runs out of process.
///
/// That is what keeps the sign-in screen's promise literally true — the app cannot read the page
/// it shows or reach into its fields — and what lets it reuse the standing household sign-on
/// instead of asking for the password again.
@MainActor
final class SafariLoginBrowser: NSObject, LoginBrowser, SFSafariViewControllerDelegate {
    var onClose: (() -> Void)?
    var onRedirect: ((URL) -> Void)?
    var onInitialLoad: ((Bool) -> Void)?

    /// Held strongly for the reason the authentication session had to be: as a local it belongs to
    /// a scope that ends the moment the continuation is handed over, and a deallocated view
    /// controller presents nothing while reporting nothing.
    private let controller: SFSafariViewController

    init(url: URL) {
        controller = SFSafariViewController(url: url)
        super.init()
        controller.delegate = self
        controller.dismissButtonStyle = .cancel
    }

    func present(from host: UIViewController) {
        host.present(controller, animated: true)
    }

    func dismiss() {
        controller.presentingViewController?.dismiss(animated: true)
    }

    var isOnScreen: Bool { controller.viewIfLoaded?.window != nil }

    nonisolated func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
        MainActor.assumeIsolated { onClose?() }
    }

    nonisolated func safariViewController(
        _ controller: SFSafariViewController,
        didCompleteInitialLoad didLoadSuccessfully: Bool
    ) {
        MainActor.assumeIsolated { onInitialLoad?(didLoadSuccessfully) }
    }

    nonisolated func safariViewController(
        _ controller: SFSafariViewController,
        initialLoadDidRedirectTo url: URL
    ) {
        MainActor.assumeIsolated { onRedirect?(url) }
    }
}
