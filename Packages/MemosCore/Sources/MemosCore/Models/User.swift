import Foundation
import MemosAPI

/// Who the token belongs to. `GET /api/auth/user` is also how a pasted token is validated, so this
/// type doubles as the proof that a credential works.
public struct User: Sendable, Equatable, Identifiable, Codable {
    public var subject: String
    public var displayName: String?
    public var email: String?
    public var role: String
    public var authKind: String

    public init(
        subject: String,
        displayName: String? = nil,
        email: String? = nil,
        role: String,
        authKind: String
    ) {
        self.subject = subject
        self.displayName = displayName
        self.email = email
        self.role = role
        self.authKind = authKind
    }

    public var id: String { subject }

    /// What to call this account: the display name, else the address, else the subject. A value
    /// that is blank — empty, or nothing but whitespace — is passed over as if it were absent,
    /// because `??` alone takes `""` for a name and a screen then reads "signed in as , …". A value
    /// that is not blank is handed over as it came, whitespace around it included.
    public var name: String {
        for candidate in [displayName, email] {
            if let candidate, !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return candidate
            }
        }
        return subject
    }
}

extension User {
    public init(_ generated: Components.Schemas.UserOut) {
        self.init(
            subject: generated.subject,
            displayName: generated.displayName,
            email: generated.email,
            role: generated.role,
            authKind: generated.authKind
        )
    }
}
