import Foundation

/// Where the device credential lives, which namespaces it is still being collected from, and how
/// all three are named on a build that carries no team id.
///
/// There have been three homes, and a device can be carrying its token in any of them:
///
/// 1. `<team>.live.discomarder.memosng` — the application-identifier group, where a sign-in wrote
///    before any entitlement existed.
/// 2. `group.live.discomarder.memosng` — the app group, taken as a keychain group so "the app and
///    its extensions read one token". That was the mistake this round closes: on iOS an app group
///    identifier IS a keychain access group, so the share extension — which needs the group's
///    CONTAINER for the outbox files and the identity JSON — could read the token as well.
/// 3. `$(AppIdentifierPrefix)live.discomarder.memosng.credentials` — a group named in
///    `keychain-access-groups` on the APP target and nowhere else. The extension's entitlements
///    do not contain it, so the extension cannot name it and cannot reach it.
///
/// Nobody is signed out to get from one to the next: whichever namespace still holds the token,
/// the first read moves it home (see `CredentialVault`).
///
/// **What only a signed device build can prove.** The simulator does not enforce keychain access
/// groups, so no test that runs in it can show that the share extension is refused. What runs
/// here is the arithmetic — that the token's home is never the app group, that the three names
/// are derived correctly from what the probe reports, and that the entitlement files say what
/// they must (the gate greps the generated pair). The isolation itself is a device ceremony:
/// install a signed build, sign in, and have the share extension attempt a read of
/// `service = live.discomarder.memosng` in the app group and in the credentials group. The first
/// must find nothing; the second must fail with `errSecMissingEntitlement`.
public enum DeviceCredentials {
    /// The keychain service every namespace uses. Unchanged by both moves: only the access group
    /// changes, and changing both at once would make the older items unfindable.
    public static let service = "live.discomarder.memosng"

    /// The app's bundle identifier, which is also the tail of its application-identifier access
    /// group — the first home, above.
    public static let bundleIdentifier = "live.discomarder.memosng"

    /// The app group. It is a keychain access group too, which is why the token is not in it.
    public static let appGroup = "group.live.discomarder.memosng"

    /// The tail of the app-only group the token lives in now. The team id enters at build time,
    /// through `$(AppIdentifierPrefix)` in the entitlement, and never at rest in this repository.
    public static let credentialsGroupTail = "live.discomarder.memosng.credentials"

    /// The ONE vault in the process.
    ///
    /// Serialization is a property of the object: two vaults over the same keychain would
    /// serialize nothing, and the session's wipe and the outbox's read have to be two calls on
    /// the same one. Everything that stores a credential in this app comes through here.
    public static let shared: any CredentialStore = CredentialVault(resolving: { namespaces() })

    public static func keychain() -> any CredentialStore { shared }

    /// The three namespaces, as stores.
    static func namespaces() -> CredentialNamespaces? {
        guard let plan = plan() else { return nil }
        return CredentialNamespaces(
            primary: CredentialNamespace(
                Keychain(service: service, accessGroup: plan.primary.accessGroup),
                reach: plan.primary.reach
            ),
            legacies: plan.legacies.map {
                CredentialNamespace(
                    Keychain(service: service, accessGroup: $0.accessGroup), reach: $0.reach)
            },
            // A home that is not the entitlement's own group reads and clears, and refuses to
            // take a new credential. The alternative — storing it somewhere weaker without
            // saying so — is a security policy changing itself quietly.
            homeIsDedicated: plan.dedicatedGroupInEffect
        )
    }

    /// The plan for THIS build, or nil while the probe will not resolve.
    static func plan() -> KeychainNamespacePlan? {
        KeychainAccessGroup.appDefault.flatMap(plan(default:))
    }

    /// Which of the three namespaces is the token's home, worked out from the one thing this app
    /// can observe about its own entitlements: the group an unqualified add lands in.
    ///
    /// Probing rather than assembling is what lets a repository with no team id name a
    /// team-prefixed group at all. It also makes the entitlement's presence EVIDENCE rather than
    /// an assumption: the dedicated group is the default access group exactly when
    /// `keychain-access-groups` is in effect and names it first, so a probe that reports it has
    /// proved the entitlement reached the running build.
    ///
    /// - Parameter probed: what `KeychainAccessGroup.appDefault` reported.
    /// - Returns: nil when nothing usable can be named — including the one answer that must never
    ///   be used, the app group itself.
    static func plan(default probed: String) -> KeychainNamespacePlan? {
        guard !probed.isEmpty, probed != appGroup else { return nil }
        let shared = KeychainNamespacePlan.Namespace(
            accessGroup: appGroup, reach: .sharedWithExtensions)

        if let prefix = prefix(of: probed, endingWith: credentialsGroupTail) {
            // The dedicated group IS the default, so the entitlement is in effect on this build.
            return KeychainNamespacePlan(
                primary: KeychainNamespacePlan.Namespace(accessGroup: probed, reach: .appOnly),
                legacies: [
                    shared,
                    KeychainNamespacePlan.Namespace(
                        accessGroup: prefix + bundleIdentifier, reach: .appOnly),
                ],
                dedicatedGroupInEffect: true
            )
        }

        if let prefix = prefix(of: probed, endingWith: bundleIdentifier) {
            // No dedicated group in effect — an older build, or a simulator that does not apply
            // the entitlement. The application-identifier group is the home instead: it is app-only
            // too (the extension's application identifier is a different one), so the token is
            // still out of the extension's reach. The dedicated group goes in the legacies, which
            // is how a device that HAS migrated finds its token again on a build that has not.
            return KeychainNamespacePlan(
                primary: KeychainNamespacePlan.Namespace(accessGroup: probed, reach: .appOnly),
                legacies: [
                    shared,
                    KeychainNamespacePlan.Namespace(
                        accessGroup: prefix + credentialsGroupTail, reach: .appOnly),
                ],
                dedicatedGroupInEffect: false
            )
        }

        // Some other group is the default. It is one this build is entitled to and it is not the
        // app group, so the token may live there — but no other name can be derived from it, so
        // none is claimed.
        return KeychainNamespacePlan(
            primary: KeychainNamespacePlan.Namespace(accessGroup: probed, reach: .appOnly),
            legacies: [shared],
            dedicatedGroupInEffect: false
        )
    }

    /// The part before a trailing `.<tail>`: `"TEAM."` for a device build, `""` when the whole
    /// string IS the tail — which is what a build with no team prefix reports — and nil when it
    /// does not end there at all.
    static func prefix(of group: String, endingWith tail: String) -> String? {
        if group == tail { return "" }
        guard group.hasSuffix("." + tail) else { return nil }
        return String(group.dropLast(tail.count))
    }
}

/// Which access group holds the credential, and which ones are still being emptied into it.
///
/// A value of this type is only ever constructed with a primary no extension can reach and
/// legacies that are all different from it — the initializer refuses anything else, so a plan
/// that would put the token where the share extension can read it has no representation.
struct KeychainNamespacePlan: Equatable, Sendable {
    struct Namespace: Equatable, Sendable {
        let accessGroup: String
        let reach: CredentialReach

        init(accessGroup: String, reach: CredentialReach) {
            self.accessGroup = accessGroup
            self.reach = reach
        }
    }

    let primary: Namespace
    let legacies: [Namespace]
    /// True when the probe PROVED the dedicated app-only group is in effect on this build. False
    /// is not a fallback to a weaker home for WRITES — see `CredentialNamespaces.homeIsDedicated`
    /// — it is a device that can still read and still sign out, and cannot sign in.
    let dedicatedGroupInEffect: Bool

    init?(primary: Namespace, legacies: [Namespace], dedicatedGroupInEffect: Bool) {
        guard primary.reach == .appOnly, !primary.accessGroup.isEmpty else { return nil }
        guard !legacies.contains(where: { $0.accessGroup.isEmpty }) else { return nil }
        // Disjoint by name, which is what makes "a delete in one cannot reach the other" true of
        // the plan and not only of each query.
        guard !legacies.contains(where: { $0.accessGroup == primary.accessGroup }) else {
            return nil
        }
        guard Set(legacies.map(\.accessGroup)).count == legacies.count else { return nil }
        self.primary = primary
        self.legacies = legacies
        self.dedicatedGroupInEffect = dedicatedGroupInEffect
    }
}
