import Foundation

/// Who will see the memo, in the server's own words.
///
/// The values are mirrored here rather than imported: the type that names them for the app lives
/// in a layer the extension may not link, and `UploadJob.visibility` is a raw wire string anyway.
/// `nil` — not a case of this enum — is the account's own default, which is what a share from
/// outside the app should normally get: someone sharing a photo in two taps has not been asked a
/// question about audiences, and answering one for them is worse than deferring to their setting.
public enum ShareVisibility: String, Sendable, Equatable, CaseIterable {
    case `private` = "PRIVATE"
    case protected = "PROTECTED"
    case `public` = "PUBLIC"
}
