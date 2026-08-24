import SwiftUI
import UIKit

/// The share sheet's entry point, named by `NSExtensionPrincipalClass`.
///
/// It exists because a share extension is still a UIKit host: there is no SwiftUI lifecycle to
/// declare one with, and the extension context — the only way to say "I am finished with this
/// share" — belongs to a view controller. Everything above that is SwiftUI, and everything worth
/// testing is below it, in MemosShareKit.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()

        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }
        let host = UIHostingController(
            rootView: ShareRootView(
                providers: providers,
                finish: { [weak self] in
                    // The share is on disk in the app group; the app uploads it when it next
                    // drains. Returning no items is right: this extension changes nothing about
                    // what it was given.
                    self?.extensionContext?.completeRequest(returningItems: [])
                },
                cancel: { [weak self] in
                    self?.extensionContext?.cancelRequest(
                        withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)
                    )
                }
            )
        )

        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        host.didMove(toParent: self)
    }
}
