import Foundation

/// Where a client points.
///
/// Sign-in takes a server address typed by a person, so the parsing lives here rather than in a
/// view: a bare host has to become an `https` URL, a trailing slash must not produce a double
/// slash in every request path, and a plain-`http` address is refused because the personal access
/// token would then travel in clear text.
public struct ServerConfiguration: Sendable, Equatable {
    public let baseURL: URL

    public init(baseURL: URL) {
        self.baseURL = baseURL
    }

    /// Parses an address as typed into the sign-in field. Returns `nil` when it cannot become a
    /// usable `https` base URL.
    public init?(serverAddress: String) {
        let trimmed = serverAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard var components = URLComponents(string: withScheme) else { return nil }
        guard components.scheme?.lowercased() == "https" else { return nil }
        guard let host = components.host, !host.isEmpty else { return nil }

        // Every request path in the contract is absolute (`/api/...`), so a base URL that keeps a
        // trailing slash or a path of its own would produce `//api/...` or a wrong prefix.
        components.path = ""
        components.query = nil
        components.fragment = nil
        guard let url = components.url else { return nil }
        self.baseURL = url
    }

    /// The address as a person types it back into the sign-in field: the base URL without its
    /// scheme, so `https://memos.example.com:8443` reads `memos.example.com:8443`.
    ///
    /// Cut from the absolute string rather than rebuilt from `host` and `port`, because that is
    /// the form `init?(serverAddress:)` accepts again unchanged — an IPv6 literal keeps its
    /// brackets, which `URLComponents.host` drops.
    public var displayAddress: String {
        let absolute = baseURL.absoluteString
        guard let separator = absolute.range(of: "://") else { return absolute }
        return String(absolute[separator.upperBound...])
    }
}
