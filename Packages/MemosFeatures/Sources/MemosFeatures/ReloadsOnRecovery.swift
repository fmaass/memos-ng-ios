import SwiftUI

extension View {
    /// Reads whatever this screen shows again when the server has come back.
    ///
    /// The counter arrives by value rather than as the session, so the screens that use it stay
    /// hostable and the modifier has nothing to read out of the environment. What it reacts to is
    /// the counter CHANGING, which is why a screen appearing for the first time — with whatever
    /// number the session happens to be on — reloads nothing.
    func reloadsOnRecovery(
        _ counter: Int,
        perform: @MainActor @escaping () async -> Void
    ) -> some View {
        onChange(of: counter) { _, _ in
            Task { await perform() }
        }
    }
}
