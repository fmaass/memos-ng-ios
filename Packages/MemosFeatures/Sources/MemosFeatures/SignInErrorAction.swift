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
