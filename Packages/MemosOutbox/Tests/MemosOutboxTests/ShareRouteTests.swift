import Foundation
import MemosOutbox
import Testing

@Suite("Which queue a share goes into")
struct ShareRouteTests {
    private static let door = URL(string: "https://trip.example.invalid")!

    private static func member(owner: String = "fabian") -> PublishedLicence {
        PublishedLicence(binding: Fixture.binding(owner: owner), incarnation: UUID())
    }

    private static func guest(device: String = "guest-device-1") -> PublishedLicence {
        PublishedLicence(
            binding: AccountBinding(serverBaseURL: door, ownerSubject: device, kind: .guest),
            incarnation: UUID()
        )
    }

    /// The two licence files as the extension finds them: the member's beside the member queue,
    /// the guest's beside the guest queue, in one container.
    private func withStores(
        _ body: (_ member: OutboxAccountStore, _ guest: OutboxAccountStore) throws -> Void
    ) throws {
        let container = try Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }
        try body(
            OutboxAccountStore(root: container.appending(path: "outbox")),
            OutboxAccountStore(root: container.appending(path: "guest-outbox"))
        )
    }

    @Test("a guest pass alone sends the share to the trip, stamped as the guest")
    func guestOnly() {
        let guest = Self.guest()
        let route = ShareRoute.resolve(member: nil, guest: guest)
        #expect(route?.kind == .guest)
        #expect(route?.licence == guest)
        #expect(route?.licence.binding.credentialKind == .guest)
    }

    @Test("a member alone sends the share home")
    func memberOnly() {
        let member = Self.member()
        let route = ShareRoute.resolve(member: member, guest: nil)
        #expect(route?.kind == .member)
        #expect(route?.licence == member)
    }

    @Test("with both licences standing, the guest pass wins")
    func bothGuestWins() {
        let guest = Self.guest()
        let route = ShareRoute.resolve(member: Self.member(), guest: guest)
        #expect(route?.kind == .guest)
        #expect(route?.licence == guest)
    }

    @Test("with neither licence there is nowhere to send a share")
    func neither() {
        #expect(ShareRoute.resolve(member: nil, guest: nil) == nil)
        #expect(ShareRoute.licence(for: .member, member: nil, guest: nil) == nil)
        #expect(ShareRoute.licence(for: .guest, member: nil, guest: nil) == nil)
    }

    @Test("a pass that ended between the sheet opening and the enqueue stamps nothing")
    func guestVanishedAtEnqueue() throws {
        try withStores { member, guest in
            member.publish(Self.member().binding)
            guest.publish(Self.guest().binding)
            // What the sheet saw when it opened.
            let opened = ShareRoute.resolve(
                member: member.currentLicence(), guest: guest.currentLicence()
            )
            #expect(opened?.kind == .guest)

            // The app ends the pass while the sheet stands.
            try guest.clear()

            // The member is still signed in, and that must not become the trip capture's home.
            #expect(
                ShareRoute.licence(
                    for: .guest, member: member.currentLicence(), guest: guest.currentLicence()
                ) == nil
            )
            // A fresh sheet would go home, which is right for a share composed from now on.
            #expect(
                ShareRoute.resolve(member: member.currentLicence(), guest: guest.currentLicence())?
                    .kind == .member
            )
        }
    }

    @Test("a pass that arrived under a member's sheet does not turn the share into the guest's")
    func guestArrivedUnderMemberSheet() throws {
        try withStores { member, guest in
            member.publish(Self.member().binding)
            #expect(
                ShareRoute.resolve(member: member.currentLicence(), guest: guest.currentLicence())?
                    .kind == .member
            )
            guest.publish(Self.guest().binding)
            #expect(
                ShareRoute.licence(
                    for: .member, member: member.currentLicence(), guest: guest.currentLicence()
                ) == nil
            )
        }
    }

    @Test("the licence a still-standing route is stamped with is the one read at the enqueue")
    func licenceIsTheCurrentRead() throws {
        try withStores { member, guest in
            guest.publish(Self.guest(device: "first").binding)
            let before = guest.currentLicence()
            try guest.clear()
            guest.publish(Self.guest(device: "second").binding)
            let stamped = ShareRoute.licence(
                for: .guest, member: member.currentLicence(), guest: guest.currentLicence()
            )
            #expect(stamped?.binding.ownerSubject == "second")
            #expect(stamped != before)
        }
    }

    @Test("a licence of the other kind in either file is no licence for that queue")
    func kindMustMatchItsQueue() {
        // A member binding found in the guest queue's file: never a guest route.
        let memberInGuestFile = Self.member()
        #expect(ShareRoute.resolve(member: nil, guest: memberInGuestFile) == nil)
        #expect(ShareRoute.licence(for: .guest, member: nil, guest: memberInGuestFile) == nil)
        // ...and it does not outrank the real member licence either.
        let member = Self.member(owner: "anna")
        #expect(ShareRoute.resolve(member: member, guest: memberInGuestFile)?.licence == member)

        // A guest binding found in the member queue's file: never a member route.
        let guestInMemberFile = Self.guest()
        #expect(ShareRoute.resolve(member: guestInMemberFile, guest: nil) == nil)
        #expect(ShareRoute.licence(for: .member, member: guestInMemberFile, guest: nil) == nil)
    }

    @Test("an unreadable guest licence is no pass: the share goes home, never to a guessed trip")
    func unreadableGuestLicence() throws {
        let container = try Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }
        let member = OutboxAccountStore(root: container.appending(path: "outbox"))
        let guest = OutboxAccountStore(root: container.appending(path: "guest-outbox"))
        member.publish(Self.member().binding)
        let file = container.appending(path: "guest-outbox/account.json")
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("not json".utf8).write(to: file)

        let route = ShareRoute.resolve(
            member: member.currentLicence(), guest: guest.currentLicence()
        )
        #expect(route?.kind == .member)
        #expect(
            ShareRoute.licence(
                for: .guest, member: member.currentLicence(), guest: guest.currentLicence()
            ) == nil
        )
    }
}
