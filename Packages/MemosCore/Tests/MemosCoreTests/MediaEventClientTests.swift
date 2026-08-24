import Foundation
@testable import MemosCore
import Testing

@Suite("MediaEventClient")
struct MediaEventClientTests {
    @Test("a connection delivers the server's events in order, then the channel waits")
    func deliversTheStream() async {
        let transport = ScriptedSSETransport([.whole(SSEFixture.liveStream)])
        let sleeper = RecordingSleeper(budget: 1)
        let client = LiveStub.client(transport: transport, sleeper: sleeper)

        let items = await client.collect()

        #expect(items.events == SSEFixture.liveEvents)
        #expect(items.states.first == .connecting(attempt: 1))
        #expect(items.states.contains(.open))
        #expect(await transport.connectCount == 1)
    }

    @Test("the boundaries the network chose do not change what the channel delivers")
    func chunkBoundariesDoNotMatter() async {
        let transport = ScriptedSSETransport([.bytewise(SSEFixture.liveStream)])
        let sleeper = RecordingSleeper(budget: 1)
        let client = LiveStub.client(transport: transport, sleeper: sleeper)

        let items = await client.collect()

        #expect(items.events == SSEFixture.liveEvents)
    }

    @Test("the request carries the bearer, the stream Accept, and no stale resumption point")
    func requestShape() async {
        let transport = ScriptedSSETransport([.whole(SSEFixture.liveStream)])
        let sleeper = RecordingSleeper(budget: 1)
        let client = LiveStub.client(transport: transport, sleeper: sleeper)

        _ = await client.collect()

        #expect(await transport.url(of: 0) == "https://memos.example.invalid/api/events")
        #expect(await transport.header("Authorization", of: 0) == "Bearer memos_pat_live")
        #expect(await transport.header("Accept", of: 0) == "text/event-stream")
        #expect(await transport.header("Last-Event-ID", of: 0) == nil)
    }

    @Test("a stream that declares ids is resumed from the last one on the next connection")
    func resumesFromTheLastEventID() async {
        let idFrame = "id: 42\n" + SSEFixture.liveFrames[0]
        let transport = ScriptedSSETransport([
            .dropping(after: idFrame),
            .whole(SSEFixture.liveStream),
        ])
        let sleeper = RecordingSleeper(budget: 2)
        let client = LiveStub.client(transport: transport, sleeper: sleeper)

        let items = await client.collect()

        #expect(await transport.header("Last-Event-ID", of: 0) == nil)
        #expect(await transport.header("Last-Event-ID", of: 1) == "42")
        #expect(items.events.count == 6, "the id frame's event plus the five that followed")
    }

    @Test("failures escalate the wait until a connection opens")
    func backoffEscalates() async {
        let transport = ScriptedSSETransport([
            .unreachable(),
            .unreachable(),
            .unreachable(),
            .whole(SSEFixture.liveStream),
        ])
        let sleeper = RecordingSleeper(budget: 4)
        let client = LiveStub.client(transport: transport, sleeper: sleeper)

        let items = await client.collect()

        // 1s, 2s, 4s while it cannot connect; the fourth wait is the IDLE delay, because the
        // connection that opened reset the schedule.
        #expect(await sleeper.waits == [1, 2, 4, 15])
        #expect(await transport.connectCount == 4)
        #expect(items.events == SSEFixture.liveEvents)
    }

    @Test("the server closing a quiet stream is not a failure and does not escalate")
    func cleanEndsDoNotEscalate() async {
        // An empty script answers the way the real server does with nothing in flight: 200, no
        // events, closed at once (memos-ng `app/routers/assets.py:763-764`).
        let transport = ScriptedSSETransport()
        let sleeper = RecordingSleeper(budget: 3)
        let client = LiveStub.client(transport: transport, sleeper: sleeper)

        _ = await client.collect()

        #expect(await sleeper.waits == [15, 15, 15])
        #expect(await transport.connectCount == 3)
    }

    @Test("a retry the stream asked for replaces the client's own first wait")
    func serverRetryHintIsHonoured() async {
        let transport = ScriptedSSETransport([.dropping(after: "retry: 5000\n\n")])
        let sleeper = RecordingSleeper(budget: 1)
        let client = LiveStub.client(transport: transport, sleeper: sleeper)

        _ = await client.collect()

        #expect(await sleeper.waits == [5])
    }

    @Test("a refused credential stops the channel instead of retrying with it")
    func unauthorizedIsTerminal() async {
        let transport = ScriptedSSETransport([.status(401)])
        let sleeper = RecordingSleeper(budget: 4)
        let client = LiveStub.client(transport: transport, sleeper: sleeper)

        let items = await client.collect()

        #expect(items.states.last == .stopped(.unauthorized))
        #expect(await transport.connectCount == 1)
        #expect(await sleeper.waits.isEmpty)
    }

    @Test("a server error is retried, unlike a refusal")
    func serverErrorsAreRetried() async {
        let transport = ScriptedSSETransport([.status(502), .whole(SSEFixture.liveStream)])
        let sleeper = RecordingSleeper(budget: 2)
        let client = LiveStub.client(transport: transport, sleeper: sleeper)

        let items = await client.collect()

        #expect(await sleeper.waits == [1, 15])
        #expect(items.events == SSEFixture.liveEvents)
    }

    @Test("with nobody signed in there is nothing to stream and nothing to connect to")
    func signedOutIsTerminal() async {
        let transport = ScriptedSSETransport([.whole(SSEFixture.liveStream)])
        let sleeper = RecordingSleeper(budget: 4)
        let client = LiveStub.client(transport: transport, sleeper: sleeper, credentials: nil)

        let items = await client.collect()

        #expect(items.states.last == .stopped(.signedOut))
        #expect(await transport.connectCount == 0)
    }

    @Test("an account switch between connections stops the channel before it reconnects")
    func identityRotationBeforeReconnect() async {
        // Read 1 is the fence; read 2 is the gate at the top of the loop, and it has moved.
        let generation = ScriptedGeneration(rotatesAfter: 1)
        let transport = ScriptedSSETransport([.whole(SSEFixture.liveStream)])
        let sleeper = RecordingSleeper(budget: 4)
        let client = LiveStub.client(
            transport: transport,
            sleeper: sleeper,
            generation: generation
        )

        let items = await client.collect()

        #expect(items.states.last == .stopped(.identityChanged))
        #expect(await transport.connectCount == 0)
    }

    @Test("an account switch mid-stream drops the events that connection was still carrying")
    func identityRotationMidStream() async {
        // Read 1 fence, read 2 the loop gate, read 3 the per-chunk gate — which has moved, with a
        // chunk of five decodable events in hand.
        let generation = ScriptedGeneration(rotatesAfter: 2)
        let transport = ScriptedSSETransport([.whole(SSEFixture.liveStream)])
        let sleeper = RecordingSleeper(budget: 4)
        let client = LiveStub.client(
            transport: transport,
            sleeper: sleeper,
            generation: generation
        )

        let items = await client.collect()

        #expect(items.events.isEmpty, "not one event of account A's may reach account B")
        #expect(items.states.contains(.open))
        #expect(items.states.last == .stopped(.identityChanged))
        #expect(await transport.connectCount == 1)
    }

    @Test("an event already delivered is refused once the device is another account")
    @MainActor
    func stampedEventIsRefusedAfterRotation() {
        // The window the in-channel gate cannot cover: the event was received, stamped and
        // buffered under this generation, and the account rotates before anything applies it.
        // No sleeping, no scheduling — rotation is just the clock moving between the two calls.
        let identity = MediaIdentity()
        let envelope = MediaEventEnvelope(
            event: SSEFixture.liveEvents[0],
            generation: identity.generation
        )

        identity.rotate()

        #expect(
            envelope.eventIfCurrent(for: identity) == nil,
            "an event fenced to the previous account must not reach the new one's timeline"
        )
    }

    @Test("an event still fenced to the account the device is on is handed over to be applied")
    @MainActor
    func stampedEventIsAcceptedWhileCurrent() {
        let identity = MediaIdentity()
        identity.rotate()
        let envelope = MediaEventEnvelope(
            event: SSEFixture.liveEvents[2],
            generation: identity.generation
        )

        #expect(envelope.eventIfCurrent(for: identity) == SSEFixture.liveEvents[2])
    }

    @Test("every delivered event is stamped with the generation the channel was fenced to")
    @MainActor
    func deliveredEventsCarryTheFence() async throws {
        let identity = MediaIdentity()
        identity.rotate()
        identity.rotate()
        let store = InMemoryCredentials()
        try store.set("memos_pat_stored", for: SessionStore.tokenAccount)
        try store.set("https://memos.stored.invalid", for: SessionStore.serverAccount)
        let transport = ScriptedSSETransport([.whole(SSEFixture.liveStream)])
        let sleeper = RecordingSleeper(budget: 1)
        let client = MediaEventClient.device(
            credentials: store,
            identity: identity,
            transport: transport,
            sleeper: sleeper
        )

        let items = await client.collect()

        #expect(items.events == SSEFixture.liveEvents)
        #expect(
            items.envelopes.allSatisfy { $0.generation == 2 },
            "the stamp is the live clock the channel read, not a constant"
        )
        #expect(items.envelopes.allSatisfy { $0.eventIfCurrent(for: identity) != nil })
    }

    @Test("frames this client cannot read are skipped, and the ones around them still arrive")
    func unknownFramesAreSkipped() async {
        let stream =
            SSEFixture.liveFrames[0]
            + #"data: {"uid": "x", "status": "quarantined", "progress_pct": 5}"# + "\n\n"
            + "event: keepalive\ndata: {}\n\n"
            + "data: not json at all\n\n"
            + ": a comment\n\n"
            + SSEFixture.liveFrames[1]
        let transport = ScriptedSSETransport([.whole(stream)])
        let sleeper = RecordingSleeper(budget: 1)
        let client = LiveStub.client(transport: transport, sleeper: sleeper)

        let items = await client.collect()

        #expect(items.events == [SSEFixture.liveEvents[0], SSEFixture.liveEvents[1]])
        #expect(items.states.contains(.waiting(15)), "the connection still ended cleanly")
    }

    @Test("a consumer that stops consuming closes the connection")
    func cancellingClosesTheConnection() async {
        let transport = ScriptedSSETransport([.open(SSEFixture.liveFrames[0])])
        let sleeper = RecordingSleeper(budget: 4)
        let client = LiveStub.client(transport: transport, sleeper: sleeper)

        var received: [MediaEvent] = []
        for await item in client.stream() {
            guard case .event(let envelope) = item else { continue }
            received.append(envelope.event)
            break
        }
        #expect(received == [SSEFixture.liveEvents[0]])

        var closed = false
        for _ in 0..<100 where !closed {
            if await transport.terminationCount() > 0 {
                closed = true
            } else {
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        #expect(closed, "the open connection outlived the consumer")
    }

    @Test("the device channel presents the stored credential against the stored server")
    @MainActor
    func deviceCredentials() async throws {
        let store = InMemoryCredentials()
        try store.set("memos_pat_stored", for: SessionStore.tokenAccount)
        try store.set("https://memos.stored.invalid", for: SessionStore.serverAccount)
        let transport = ScriptedSSETransport([.whole(SSEFixture.liveStream)])
        let sleeper = RecordingSleeper(budget: 1)
        let client = MediaEventClient.device(
            credentials: store,
            identity: MediaIdentity(),
            transport: transport,
            sleeper: sleeper
        )

        let items = await client.collect()

        #expect(items.events == SSEFixture.liveEvents)
        #expect(await transport.url(of: 0) == "https://memos.stored.invalid/api/events")
        #expect(await transport.header("Authorization", of: 0) == "Bearer memos_pat_stored")
    }

    @Test("the device channel with nothing stored never opens a connection")
    @MainActor
    func deviceWithoutACredential() async {
        let transport = ScriptedSSETransport([.whole(SSEFixture.liveStream)])
        let sleeper = RecordingSleeper(budget: 4)
        let client = MediaEventClient.device(
            credentials: InMemoryCredentials(),
            identity: MediaIdentity(),
            transport: transport,
            sleeper: sleeper
        )

        let items = await client.collect()

        #expect(items.states.last == .stopped(.signedOut))
        #expect(await transport.connectCount == 0)
        // Half of the distinction the other half is asserted against: an EMPTY store is an answer,
        // and the answer is that nobody is signed in. Nothing about that improves by waiting.
        #expect(await sleeper.waits.isEmpty, "absent is terminal — there is nothing to retry for")
    }

    @Test("a store that will not answer is a failed connection, not a sign-out")
    @MainActor
    func unreadableStorageIsNotASignOut() async {
        // `UnreadableCredentials` throws where `InMemoryCredentials` returns nil, and that is the
        // whole difference: the token may be sitting on the device, unreachable between a reboot
        // and the first unlock. Signing the channel out on it would end the channel over a
        // condition that clears itself the moment somebody unlocks the phone.
        let transport = ScriptedSSETransport([.whole(SSEFixture.liveStream)])
        let sleeper = RecordingSleeper(budget: 3)
        let client = MediaEventClient.device(
            credentials: UnreadableCredentials(),
            identity: MediaIdentity(),
            transport: transport,
            sleeper: sleeper
        )

        let items = await client.collect()

        #expect(!items.states.contains(.stopped(.signedOut)), "unreadable is not signed out")
        #expect(await sleeper.waits == [1, 2, 4], "it backs off and keeps trying")
        #expect(await transport.connectCount == 0, "and presents no credential it does not have")
    }
}

@Suite("SSEBackoff")
struct SSEBackoffTests {
    @Test("the first wait is the base and every later one doubles up to the cap")
    func escalation() {
        let backoff = SSEBackoff()
        #expect(backoff.delay(forAttempt: 1) == 1)
        #expect(backoff.delay(forAttempt: 2) == 2)
        #expect(backoff.delay(forAttempt: 3) == 4)
        #expect(backoff.delay(forAttempt: 6) == 30)
        #expect(backoff.delay(forAttempt: 60) == 30, "the cap holds, and pow does not overflow")
    }

    @Test("a retry the server asked for replaces the base and is never shrunk to the cap")
    func serverHint() {
        let backoff = SSEBackoff()
        #expect(backoff.delay(forAttempt: 1, serverHint: 5) == 5)
        #expect(backoff.delay(forAttempt: 2, serverHint: 5) == 10)
        #expect(backoff.delay(forAttempt: 3, serverHint: 5) == 20)
        #expect(backoff.delay(forAttempt: 1, serverHint: 120) == 120)
        #expect(backoff.delay(forAttempt: 4, serverHint: 120) == 120, "the hint is the floor here")
    }

    @Test("a nonsensical hint cannot make the channel spin")
    func negativeHint() {
        #expect(SSEBackoff().delay(forAttempt: 1, serverHint: -5) == 0)
    }
}
