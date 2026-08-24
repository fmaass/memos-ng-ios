import Foundation
@testable import MemosCore
import Security
import Testing

/// Which of the three keychain namespaces the device token lives in, worked out from the one
/// thing the app can observe about its own entitlements: the group an unqualified add lands in.
///
/// The derivation is a pure function precisely so that it can be held still here. What it CANNOT
/// prove is the isolation itself: the simulator does not enforce keychain access groups, so no
/// test running in it can show the share extension being refused. That is a device ceremony, and
/// what stands in for it here is this arithmetic plus the gate's grep over the generated
/// entitlement files.
@Suite("Credential namespaces")
struct CredentialNamespacePlanTests {
    private let appGroup = "group.live.discomarder.memosng"
    private let deviceDefault = "ABCDE12345.live.discomarder.memosng.credentials"
    private let deviceBundleGroup = "ABCDE12345.live.discomarder.memosng"

    @Test("a signed build keeps the token in the group only the app names")
    func dedicatedGroupIsTheHome() throws {
        let plan = try #require(DeviceCredentials.plan(default: deviceDefault))

        #expect(plan.primary.accessGroup == deviceDefault)
        #expect(plan.primary.reach == .appOnly)
        #expect(plan.dedicatedGroupInEffect, "the probe reported the entitlement's own group")
        #expect(
            plan.legacies.map(\.accessGroup) == [appGroup, deviceBundleGroup],
            "and both older homes are emptied into it, the app group first"
        )
        #expect(plan.legacies.first?.reach == .sharedWithExtensions)
        #expect(plan.legacies.last?.reach == .appOnly)
    }

    @Test("a build with no team prefix names the same three namespaces")
    func noTeamPrefixStillNamesThree() throws {
        let plan = try #require(
            DeviceCredentials.plan(default: "live.discomarder.memosng.credentials"))

        #expect(plan.primary.accessGroup == "live.discomarder.memosng.credentials")
        #expect(plan.dedicatedGroupInEffect)
        #expect(plan.legacies.map(\.accessGroup) == [appGroup, "live.discomarder.memosng"])
    }

    /// An older build, or one whose entitlement did not reach the running binary. The
    /// application-identifier group is app-only as well — the extension's application identifier is
    /// a different one — so the token is still out of the extension's reach, and the dedicated
    /// group becomes a namespace to collect FROM, which is how a device that already migrated
    /// finds its token again.
    @Test("a build without the entitlement still keeps the token app-only")
    func withoutTheEntitlementTheBundleGroupIsTheHome() throws {
        let plan = try #require(DeviceCredentials.plan(default: deviceBundleGroup))

        #expect(plan.primary.accessGroup == deviceBundleGroup)
        #expect(plan.primary.reach == .appOnly)
        #expect(plan.dedicatedGroupInEffect == false)
        #expect(plan.legacies.map(\.accessGroup) == [appGroup, deviceDefault])
    }

    @Test("the app group is never the token's home")
    func theAppGroupIsNeverTheHome() {
        #expect(DeviceCredentials.plan(default: appGroup) == nil)
    }

    @Test("an answer nothing can be derived from is still used as it is, and derives nothing")
    func anUnrecognisedDefaultGroupNamesOnlyItself() throws {
        let plan = try #require(DeviceCredentials.plan(default: "ABCDE12345.some.other.app"))

        #expect(plan.primary.accessGroup == "ABCDE12345.some.other.app")
        #expect(plan.dedicatedGroupInEffect == false)
        #expect(plan.legacies.map(\.accessGroup) == [appGroup])
    }

    @Test("no answer names nothing")
    func anEmptyAnswerNamesNothing() {
        #expect(DeviceCredentials.plan(default: "") == nil)
    }

    /// The property every shape has to have, asserted over all of them at once: the token's home
    /// is app-only, it is not one of the namespaces being emptied, and the app group is always one
    /// of those — a token left there has to be able to get out.
    @Test("every plan puts the token out of the extension's reach and collects the app group")
    func everyPlanIsSafe() throws {
        for probed in [
            deviceDefault, deviceBundleGroup, "live.discomarder.memosng.credentials",
            "live.discomarder.memosng", "ABCDE12345.some.other.app",
        ] {
            let plan = try #require(DeviceCredentials.plan(default: probed), "\(probed)")
            #expect(plan.primary.reach == .appOnly, "\(probed)")
            #expect(plan.primary.accessGroup != appGroup, "\(probed)")
            let names = plan.legacies.map(\.accessGroup)
            #expect(!names.contains(plan.primary.accessGroup), "\(probed)")
            let shared = plan.legacies.first { $0.accessGroup == appGroup }
            #expect(shared?.reach == .sharedWithExtensions, "\(probed)")
        }
    }

    @Test("a plan that would put the token where an extension can read it cannot be built")
    func aSharedPrimaryHasNoRepresentation() {
        #expect(
            KeychainNamespacePlan(
                primary: KeychainNamespacePlan.Namespace(
                    accessGroup: appGroup, reach: .sharedWithExtensions),
                legacies: [],
                dedicatedGroupInEffect: false
            ) == nil
        )
        // The other half of "disjoint": a namespace cannot be both the home and a namespace being
        // emptied, or a wipe would race a migration over one item.
        #expect(
            KeychainNamespacePlan(
                primary: KeychainNamespacePlan.Namespace(
                    accessGroup: deviceDefault, reach: .appOnly),
                legacies: [
                    KeychainNamespacePlan.Namespace(accessGroup: deviceDefault, reach: .appOnly)
                ],
                dedicatedGroupInEffect: true
            ) == nil
        )
    }

    /// The names in the Swift are the names in the entitlements. They are separate artefacts —
    /// one is compiled, the other is a generated plist the gate greps — and this is the only place
    /// they are checked against each other.
    @Test("the namespace names are the ones the entitlements carry")
    func namesMatchTheEntitlements() {
        #expect(DeviceCredentials.service == "live.discomarder.memosng")
        #expect(DeviceCredentials.bundleIdentifier == "live.discomarder.memosng")
        #expect(DeviceCredentials.appGroup == appGroup)
        #expect(DeviceCredentials.credentialsGroupTail == "live.discomarder.memosng.credentials")
    }

    // MARK: - the probe behind the names

    /// `AfterFirstUnlockThisDeviceOnly` items are documented as unreachable between a reboot and
    /// the first unlock, and a background launch lands in exactly that window. A failure there is
    /// a fact about the moment, so remembering it would leave the app unable to see its own
    /// credential until somebody force-quit it.
    @Test("a probe that failed is tried again; a probe that succeeded is not")
    func onlySuccessIsRemembered() {
        let calls = Counter()
        let resolver = AccessGroupResolver(probe: {
            calls.increment()
            guard calls.count > 2 else {
                return .unavailable(errSecInteractionNotAllowed)
            }
            return .resolved("ABCDE12345.live.discomarder.memosng.credentials")
        })

        #expect(resolver.resolved() == nil)
        #expect(resolver.resolved() == nil)
        #expect(resolver.resolved() == "ABCDE12345.live.discomarder.memosng.credentials")
        #expect(resolver.resolved() == "ABCDE12345.live.discomarder.memosng.credentials")
        #expect(calls.count == 3, "the resolved group is not probed for again")
    }

    @Test("an add that reports no group at all is not a name")
    func anUnnamedProbeIsNotAName() {
        #expect(AccessGroupResolver(probe: { .unnamed }).resolved() == nil)
        #expect(AccessGroupResolver(probe: { .resolved("") }).resolved() == nil)
    }

    // MARK: - what this build can actually reach

    /// The entitlement is a line in a YAML file until the running build agrees with it. The group
    /// it names is the DEFAULT access group exactly when it is in effect, and the probe reads that
    /// back — so this is the assertion that says the keychain entitlement actually arrived. A
    /// build where it is false still reads and still signs out; it stores nothing new at all.
    @Test("the entitlement's own group is the one this build writes to")
    func theDedicatedGroupIsInEffect() throws {
        let plan = try #require(DeviceCredentials.plan())
        #expect(
            plan.dedicatedGroupInEffect,
            "the probe reported \(plan.primary.accessGroup), which is not the entitlement's group"
        )
    }

    /// The property the whole design rests on: this build can NAME a namespace of its own, and it
    /// is not the app group. Without a name there is nothing to migrate from, nothing to delete,
    /// and — crucially — the app still does not reach for the keychain with a query that names no
    /// group at all.
    @Test("this build names a namespace of its own, and it is not the app group")
    func thisBuildNamesItsOwnNamespace() throws {
        let plan = try #require(
            DeviceCredentials.plan(),
            "the probe must resolve a group; an unnameable one leaves the vault inert"
        )
        #expect(plan.primary.reach == .appOnly)
        #expect(plan.primary.accessGroup != DeviceCredentials.appGroup)
        #expect(plan.legacies.contains { $0.accessGroup == DeviceCredentials.appGroup })

        // And it is a real group this build can use, not just a string.
        let keychain = Keychain(
            service: KeychainAccessGroup.probeService, accessGroup: plan.primary.accessGroup)
        try keychain.set("memos_pat_probe", for: "namespace-round-trip")
        #expect(try keychain.string(for: "namespace-round-trip") == "memos_pat_probe")
        try keychain.remove("namespace-round-trip")
        #expect(try keychain.string(for: "namespace-round-trip") == nil)
    }
}
