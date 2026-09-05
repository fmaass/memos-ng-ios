import MemosCore

/// What a failed sign-in offers beyond its sentence.
enum SignInErrorAction: Equatable {
    /// The sentence is the whole of it.
    case nothing
    /// Take them to this app's page in Settings.
    case openSettings
}

/// Which failure earns a button, decided on the failure and nothing else.
///
/// Exactly one of them can be fixed from inside Settings: the Local Network permission the first
/// sign-in on a home LAN trips over. Offering the same button for a timeout or an offline phone
/// would point at a switch that is already right, and the person would come back none the wiser.
///
/// It is a function rather than a computed property on the view so it can be tested as what it
/// is — a decision — instead of through a screen in a headless browser.
func signInErrorAction(for failure: NativeLoginError?) -> SignInErrorAction {
    failure == .transport(.localNetworkDenied) ? .openSettings : .nothing
}

/// The same decision for the launch screen, which parks on a different failure type.
///
/// A sibling rather than an overload of the one above: `nil` is a real input on both screens, and
/// two functions of the same name taking two optionals would make `signInErrorAction(for: nil)`
/// ambiguous at every call site that has no other way to say which flow it means.
func restoreErrorAction(for failure: SessionRestoreFailure?) -> SignInErrorAction {
    failure == .localNetworkDenied ? .openSettings : .nothing
}
