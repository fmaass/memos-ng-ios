import Foundation
import MemosAPI

/// Who the token belongs to. `GET /api/auth/user` is also how a pasted token is validated, so this
/// type doubles as the proof that a credential works.
public struct User: Sendable, Equatable, Identifiable {
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
    public var name: String { displayName ?? email ?? subject }
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
