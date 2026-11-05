import Foundation

/// Addresses the app publishes about itself. They belong to the project, never to a server
/// somebody signs in to: the privacy policy describes the app, whoever's instance it talks to.
enum PublicLinks {
    // TODO(MEMNG-1128): project domain
    static let privacyPolicy = URL(string: "https://example.invalid/privacy")!
}
