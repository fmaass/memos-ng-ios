import Foundation
import MemosOutbox
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

    @Test(
        "a retry the stream asked for outlives a connection that says nothing about it",
        arguments: [
            ": keep-alive\n\n",
            // The field's name inside a comment and inside an event's data is not the field.
            ": retry: 1000\n\n",
            "data: retry: 1000\n\n",
        ]
    )
    func serverRetryHintIsKeptUntilReplaced(silentBody: String) async {
        let transport = ScriptedSSETransport([
            .dropping(after: "retry: 60000\n\n"),
            .dropping(after: silentBody),
            .dropping(after: "retry: 5000\n\n"),
        ])
        let sleeper = RecordingSleeper(budget: 3)
        let client = LiveStub.client(transport: transport, sleeper: sleeper)

        _ = await client.collect()

        // Each connection is a fresh parser, but the reconnection time is the stream's, not the
        // connection's: the second connection never changed it, so its wait is still the 60 s
        // asked for — not the 1 s base. Only a new `retry:` replaces it, shorter or not.
        #expect(await sleeper.waits == [60, 60, 5])
        #expect(await transport.connectCount == 3)
    }

    @Test(
        "a retry the stream asks for is honoured up to a ceiling, and never past it",
        arguments: [
            // A day, a value one past the ceiling, and the ceiling itself.
            ("retry: 86400000\n\n", MediaEventClient.longestServerRetry),
            ("retry: 300001\n\n", MediaEventClient.longestServerRetry),
            ("retry: 300000\n\n", 300),
        ] as [(String, TimeInterval)]
    )
    func serverRetryHintIsBounded(body: String, expected: TimeInterval) async {
        let transport = ScriptedSSETransport([
            .dropping(after: body),
            .dropping(after: ": keep-alive\n\n"),
        ])
        let sleeper = RecordingSleeper(budget: 2)
        let client = LiveStub.client(transport: transport, sleeper: sleeper)

        _ = await client.collect()

        // The bound holds for the connection that asked AND for the one after it, which said
        // nothing and so still carries the stream's hint.
        #expect(MediaEventClient.longestServerRetry == 300)
        #expect(await sleeper.waits == [expected, expected])
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

    /// What the session hands the channel: the subject and the token out of ONE object, in one
    /// instant. The channel no longer reads the vault, so this is the only way in.
    private func grant(
        token: String = "memos_pat_stored",
        server: String = "https://memos.stored.invalid"
    ) -> CredentialGrant {
        CredentialGrant(
            subject: "fabian",
            serverBaseURL: URL(string: server)!,
            token: token,
            epoch: 0
        )
    }

    @Test("every delivered event is stamped with the generation the channel was fenced to")
    @MainActor
    func deliveredEventsCarryTheFence() async throws {
        let identity = MediaIdentity()
        identity.rotate()
        identity.rotate()
        let granted = grant()
        let transport = ScriptedSSETransport([.whole(SSEFixture.liveStream)])
        let sleeper = RecordingSleeper(budget: 1)
        let client = MediaEventClient.device(
            grant: { granted },
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

    @Test("the device channel presents the session's credential against the session's server")
    @MainActor
    func deviceCredentials() async throws {
        let granted = grant()
        let transport = ScriptedSSETransport([.whole(SSEFixture.liveStream)])
        let sleeper = RecordingSleeper(budget: 1)
        let client = MediaEventClient.device(
            grant: { granted },
            identity: MediaIdentity(),
            transport: transport,
            sleeper: sleeper
        )

        let items = await client.collect()

        #expect(items.events == SSEFixture.liveEvents)
        #expect(await transport.url(of: 0) == "https://memos.stored.invalid/api/events")
        #expect(await transport.header("Authorization", of: 0) == "Bearer memos_pat_stored")
    }

    @Test("the device channel with nobody signed in never opens a connection")
    @MainActor
    func deviceWithoutACredential() async {
        let transport = ScriptedSSETransport([.whole(SSEFixture.liveStream)])
        let sleeper = RecordingSleeper(budget: 4)
        let client = MediaEventClient.device(
            grant: { nil },
            identity: MediaIdentity(),
            transport: transport,
            sleeper: sleeper
        )

        let items = await client.collect()

        #expect(items.states.last == .stopped(.signedOut))
        #expect(await transport.connectCount == 0)
        // Half of the distinction the other half is asserted against: a session with no grant is
        // an answer, and the answer is that nobody is signed in. Waiting improves nothing.
        #expect(await sleeper.waits.isEmpty, "absent is terminal — there is nothing to retry for")
    }

    /// G2, the send. The channel builds its request from the grant it can see, and then hops to
    /// the transport — a renewal fits in that hop, and this loop reconnects for as long as the
    /// screen is up, so it is the lane that meets the most of them. The credential goes on at the
    /// send, from the authority, so what leaves is what the device is holding.
    @Test("a connect whose credential moved before the hop carries the successor")
    @MainActor
    func aConnectPresentsTheCredentialItLeavesWith() async {
        let granted = grant(token: "memos_pat_first")
        let rotating = RotatingGrant("memos_pat_first")
        let authority = rotating.authority
        let transport = ScriptedSSETransport(
            [ScriptedConnection()],
            beforeConnect: { rotating.rotate(to: "memos_pat_next") }
        )
        let client = MediaEventClient.device(
            grant: { granted },
            identity: MediaIdentity(),
            transport: transport,
            sleeper: RecordingSleeper(budget: 1),
            authority: authority
        )

        _ = await client.collect()

        #expect(
            await transport.header("Authorization", of: 0) == "Bearer memos_pat_next",
            "the connect carried the token the renewal had already replaced"
        )
    }

    /// G2, the answer. A 401 to a request that presented a credential this device has SINCE
    /// replaced says nothing about the one it is holding — and this channel's 401 is terminal, so
    /// obeying it takes live updates away for the rest of the session. It re-grants and connects
    /// again instead, exactly once: a second refusal in a row is not a rotation to chase.
    @Test("a 401 about a credential already replaced does not end the channel")
    @MainActor
    func aStale401DoesNotEndTheChannel() async {
        let granted = grant(token: "memos_pat_first")
        let rotating = RotatingGrant("memos_pat_first")
        let authority = rotating.authority
        let transport = ScriptedSSETransport(
            [ScriptedConnection(statusCode: 401), ScriptedConnection()],
            // AFTER the credential went on and BEFORE the answer is judged: the instant that makes
            // the refusal one about a token this device no longer holds.
            afterPresenting: { rotating.rotate(to: "memos_pat_next") }
        )
        let client = MediaEventClient.device(
            grant: { granted },
            identity: MediaIdentity(),
            transport: transport,
            sleeper: RecordingSleeper(budget: 3),
            authority: authority
        )

        let items = await client.collect()

        #expect(
            items.states.last != .stopped(.unauthorized),
            "a refusal of a replaced credential ended a session that is perfectly valid"
        )
        // At least twice: the re-grant is immediate, and past its script this server opens and
        // closes at once, so the loop goes on reconnecting until the sleeper's budget stops it.
        #expect(await transport.connectCount >= 2, "and it did not connect again to find out")
        #expect(await transport.header("Authorization", of: 1) == "Bearer memos_pat_next")
    }

    /// F1. The channel used to read the vault itself, and the vault is not the session. Sign in
    /// as B on a device where the write fails and A's token is still stored — the state
    /// `.storedNowhere` leaves — and a vault-reading channel presents A's credential under B's
    /// session. Read from the grant, that state cannot be expressed: the subject and the token
    /// come out of one object in one instant.
    @Test("the channel presents the signed-in session's token, not whatever the vault still holds")
    @MainActor
    func deviceChannelFollowsTheSessionNotTheVault() async throws {
        let vault = InMemoryCredentials()
        try vault.set("memos_pat_a", for: SessionStore.tokenAccount)
        try vault.set("https://memos.example.invalid", for: SessionStore.serverAccount)
        let session = SessionStore(
            credentials: RefusingCredentials(),
            makeClient: { _, token in
                Stub.client(token: token) { _, _, _ in Stub.json(Stub.user) }
            }
        )
        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_b")
        #expect(session.lastError == SessionStore.storageWarning, "the premise: B did not store")
        #expect(try vault.string(for: SessionStore.tokenAccount) == "memos_pat_a")

        let transport = ScriptedSSETransport([.whole(SSEFixture.liveStream)])
        let client = MediaEventClient.device(
            grant: { [session] in session.credentialGrant() },
            identity: MediaIdentity(),
            transport: transport,
            sleeper: RecordingSleeper(budget: 1)
        )

        _ = await client.collect()

        #expect(
            await transport.header("Authorization", of: 0) == "Bearer memos_pat_b",
            "the channel presented a token belonging to an account this device has left"
        )
    }

    @Test("a credential that will not answer is a failed connection, not a sign-out")
    @MainActor
    func unreadableStorageIsNotASignOut() async {
        // A credentials closure that THROWS, where the one above returns nil, and that is the
        // whole difference: something may be there and unreachable. Signing the channel out on it
        // would end the channel over a condition that clears itself. Built through the client's
        // own initialiser rather than through `device`, because `device` reads a session in
        // memory, which cannot fail this way — the distinction belongs to whatever supplies the
        // closure, and the client's reaction to it is what is under test.
        let transport = ScriptedSSETransport([.whole(SSEFixture.liveStream)])
        let sleeper = RecordingSleeper(budget: 3)
        let client = MediaEventClient(
            credentials: { throw UnreadableCredentials.Unreadable() },
            generation: { 0 },
            jitter: FixedJitter(1),
            transport: transport,
            sleeper: sleeper
        )

        let items = await client.collect()

        #expect(!items.states.contains(.stopped(.signedOut)), "unreadable is not signed out")
        #expect(await sleeper.waits == [1, 2, 4], "it backs off and keeps trying")
        #expect(await transport.connectCount == 0, "and presents no credential it does not have")
    }

    @Test("a failure's wait is drawn from below the schedule, not the schedule itself")
    func failureWaitsAreJittered() async {
        let transport = ScriptedSSETransport([
            .unreachable(),
            .unreachable(),
            .unreachable(),
            .whole(SSEFixture.liveStream),
        ])
        let sleeper = RecordingSleeper(budget: 4)
        let client = LiveStub.client(
            transport: transport,
            sleeper: sleeper,
            jitter: FixedJitter(0.5)
        )

        _ = await client.collect()

        // Half of 1, 2 and 4; the idle wait after a clean end is not a failure and is not drawn.
        #expect(await sleeper.waits == [0.5, 1, 2, 15])
    }

    @Test(
        "a backpressure answer's Retry-After is the next wait exactly, and only the next one",
        arguments: [429, 503]
    )
    func retryAfterOverridesTheNextWaitOnly(status: Int) async {
        let transport = ScriptedSSETransport([
            .unreachable(),
            .status(status, retryAfter: 7),
            .unreachable(),
        ])
        let sleeper = RecordingSleeper(budget: 3)
        let client = LiveStub.client(
            transport: transport,
            sleeper: sleeper,
            jitter: FixedJitter(0.5)
        )

        _ = await client.collect()

        // Attempt 2 waits the header's 7 s — not jittered, and not doubled the way a base would
        // be. Attempt 3 is back on the drawn schedule, and at its THIRD step (half of 4): the
        // override did not reset the failure count.
        #expect(await sleeper.waits == [0.5, 7, 2])
    }

    @Test("Retry-After answered twice in a row is honoured twice, never doubled")
    func repeatedRetryAfterIsNotEscalated() async {
        let transport = ScriptedSSETransport([
            .unreachable(),
            .status(503, retryAfter: 7),
            .status(503, retryAfter: 7),
            .unreachable(),
        ])
        let sleeper = RecordingSleeper(budget: 4)
        let client = LiveStub.client(
            transport: transport,
            sleeper: sleeper,
            jitter: FixedJitter(0.5)
        )

        _ = await client.collect()

        #expect(await sleeper.waits == [0.5, 7, 7, 4])
    }

    @Test("Retry-After on any answer but a 429 or a 503 is not a backpressure answer")
    func retryAfterOnOtherStatusesIsIgnored() async {
        let transport = ScriptedSSETransport([
            .unreachable(),
            .status(502, retryAfter: 7),
            .unreachable(),
        ])
        let sleeper = RecordingSleeper(budget: 3)
        let client = LiveStub.client(
            transport: transport,
            sleeper: sleeper,
            jitter: FixedJitter(0.5)
        )

        _ = await client.collect()

        #expect(await sleeper.waits == [0.5, 1, 2])
    }

    @Test("Retry-After never undercuts the stream's own retry, and does not wait less than it asks")
    func retryAfterAndTheStreamHint() async {
        // A 60 s `retry:` and a 7 s Retry-After: the stream's own ask stands.
        let longHint = ScriptedSSETransport([
            .dropping(after: "retry: 60000\n\n"),
            .status(503, retryAfter: 7),
        ])
        let longSleeper = RecordingSleeper(budget: 2)
        let longClient = LiveStub.client(
            transport: longHint,
            sleeper: longSleeper,
            jitter: FixedJitter(0)
        )
        _ = await longClient.collect()
        #expect(await longSleeper.waits == [60, 60])

        // A 5 s `retry:` and a 7 s Retry-After: the header's longer ask stands, where the hint
        // alone would have come back after 5.
        let shortHint = ScriptedSSETransport([
            .dropping(after: "retry: 5000\n\n"),
            .status(503, retryAfter: 7),
        ])
        let shortSleeper = RecordingSleeper(budget: 2)
        let shortClient = LiveStub.client(
            transport: shortHint,
            sleeper: shortSleeper,
            jitter: FixedJitter(0)
        )
        _ = await shortClient.collect()
        #expect(await shortSleeper.waits == [5, 7])
    }

    @Test("a Retry-After longer than the backoff's cap is waited out to the cap, not beyond it")
    func retryAfterAboveTheCapIsClamped() async {
        // A day asked for would park the foreground channel for a day. The cap is the longest
        // this client waits on its own, so it is the longest it waits on the server's say-so too.
        let transport = ScriptedSSETransport([.status(429, retryAfter: 86400)])
        let sleeper = RecordingSleeper(budget: 1)
        let client = LiveStub.client(transport: transport, sleeper: sleeper)
        _ = await client.collect()
        #expect(await sleeper.waits == [30])

        // The cap is the one this client was given, not a number of its own.
        let wider = ScriptedSSETransport([.status(429, retryAfter: 86400)])
        let widerSleeper = RecordingSleeper(budget: 1)
        let widerClient = LiveStub.client(
            transport: wider,
            sleeper: widerSleeper,
            backoff: SSEBackoff(base: 1, cap: 45)
        )
        _ = await widerClient.collect()
        #expect(await widerSleeper.waits == [45])
    }

    @Test(
        "a Retry-After at or under the backoff's cap is the next wait exactly",
        arguments: [29.0, 30.0]
    )
    func retryAfterWithinTheCapIsUnchanged(seconds: TimeInterval) async {
        let transport = ScriptedSSETransport([.status(429, retryAfter: seconds)])
        let sleeper = RecordingSleeper(budget: 1)
        let client = LiveStub.client(transport: transport, sleeper: sleeper)

        _ = await client.collect()

        #expect(await sleeper.waits == [seconds])
    }

    @Test("a clamped Retry-After still never undercuts a longer stream retry")
    func clampedRetryAfterAndALongerStreamHint() async {
        // The stream's 60 s `retry:` is above the 30 s cap — the hint raises the ceiling rather
        // than being shrunk to it — so a day-long Retry-After clamped to 30 yields to the 60.
        let transport = ScriptedSSETransport([
            .dropping(after: "retry: 60000\n\n"),
            .status(429, retryAfter: 86400),
        ])
        let sleeper = RecordingSleeper(budget: 2)
        let client = LiveStub.client(
            transport: transport,
            sleeper: sleeper,
            jitter: FixedJitter(0)
        )

        _ = await client.collect()

        #expect(await sleeper.waits == [60, 60])
    }
}

/// A credential that rotates the way a renewal does: the token moves, its epoch moves with it,
/// and the session never ends — which is exactly why the incarnation cannot tell them apart.
final class RotatingGrant: @unchecked Sendable {
    private let lock = NSLock()
    private var grant: PresentedGrant

    init(_ token: String) { grant = PresentedGrant(token: token, epoch: 0) }

    func rotate(to token: String) {
        lock.withLock { grant = PresentedGrant(token: token, epoch: grant.epoch + 1) }
    }

    var current: PresentedGrant { lock.withLock { grant } }

    /// Built ONCE and shared, because what a send presented is recorded in the authority itself.
    lazy var authority: SendAuthority = SendAuthority({ true }, credential: { [self] in current })
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

    @Test("a draw names an exact wait: the bottom of the window, its middle and its top")
    func jitterIsExact() {
        let backoff = SSEBackoff()
        #expect(backoff.wait(forAttempt: 3, jitter: FixedJitter(0)) == 0)
        #expect(backoff.wait(forAttempt: 3, jitter: FixedJitter(0.5)) == 2)
        #expect(backoff.wait(forAttempt: 3, jitter: FixedJitter(1)) == 4)
        // Under a stream hint the window starts at the hint, not at zero.
        #expect(backoff.wait(forAttempt: 3, serverHint: 5, jitter: FixedJitter(0)) == 5)
        #expect(backoff.wait(forAttempt: 3, serverHint: 5, jitter: FixedJitter(0.5)) == 12.5)
        #expect(backoff.wait(forAttempt: 3, serverHint: 5, jitter: FixedJitter(1)) == 20)
    }

    @Test("every draw lands inside the window, and a draw outside 0...1 is held to its edge")
    func jitterStaysInsideItsWindow() {
        let backoff = SSEBackoff()
        let draws = stride(from: 0.0, through: 1.0, by: 0.125).map { $0 }
        for hint in [nil, 5.0] as [TimeInterval?] {
            for attempt in 1...10 {
                let floor = hint ?? 0
                let ceiling = backoff.delay(forAttempt: attempt, serverHint: hint)
                for draw in draws {
                    let wait = backoff.wait(
                        forAttempt: attempt,
                        serverHint: hint,
                        jitter: FixedJitter(draw)
                    )
                    #expect(wait >= floor && wait <= ceiling, "attempt \(attempt) draw \(draw)")
                }
                let below = backoff.wait(
                    forAttempt: attempt,
                    serverHint: hint,
                    jitter: FixedJitter(-1)
                )
                let above = backoff.wait(
                    forAttempt: attempt,
                    serverHint: hint,
                    jitter: FixedJitter(2)
                )
                #expect(below == floor, "attempt \(attempt)")
                #expect(above == ceiling, "attempt \(attempt)")
            }
        }
    }

    @Test("a 60 s retry the stream asked for is never undercut by the jitter")
    func aSixtySecondHintIsNeverShrunk() {
        let backoff = SSEBackoff()
        for attempt in 1...10 {
            for draw in [0, 0.5, 1.0] {
                #expect(
                    backoff.wait(forAttempt: attempt, serverHint: 60, jitter: FixedJitter(draw))
                        == 60,
                    "attempt \(attempt) draw \(draw)"
                )
            }
        }
    }
    /// The channel's loop outlives any one session: it reconnects for as long as the screen is up,
    /// presenting the credential this device held when it started. A withdrawn session must not
    /// open a stream — and the check belongs in the transport, because every reconnect is a send
    /// the client makes on its own without asking anybody.
    @Test("a session that has been withdrawn opens no stream, first attempt or reconnect")
    func aWithdrawnSessionNeverConnects() async {
        let epoch = SessionEpoch()
        let granted = epoch.current
        epoch.bump()
        let transport = ScriptedSSETransport([ScriptedConnection(), ScriptedConnection()])
        let sleeper = RecordingSleeper(budget: 3)
        let client = LiveStub.client(
            transport: transport,
            sleeper: sleeper,
            authority: SendAuthority { epoch.isCurrent(granted) }
        )

        for await _ in client.stream() {}

        #expect(await transport.requests.isEmpty, "a stream was opened for a withdrawn session")
        #expect(await transport.verdicts.allSatisfy { !$0 }, "and the authority said so each time")
    }

}

/// The real transport, through the real URL loading system: the one place the header is read.
@Suite("URLSessionSSETransport")
struct URLSessionSSETransportTests {
    @Test("a backpressure answer's Retry-After reaches the connection in seconds")
    func surfacesRetryAfter() async throws {
        let connection = try await Self.connect(status: 503, retryAfter: "7")
        #expect(connection.statusCode == 503)
        #expect(connection.retryAfter == 7)
    }

    @Test("an answer without Retry-After, or with a date in it, surfaces none")
    func surfacesNothingElse() async throws {
        #expect(try await Self.connect(status: 200, retryAfter: nil).retryAfter == nil)
        let date = "Wed, 21 Oct 2015 07:28:00 GMT"
        let dated = try await Self.connect(status: 429, retryAfter: date)
        #expect(dated.statusCode == 429)
        #expect(dated.retryAfter == nil)
    }

    @Test("only delay-seconds is read: digits, and nothing a lenient parser would let through")
    func parsesDelaySecondsOnly() {
        #expect(SSEConnection.retryAfterSeconds("7") == 7)
        #expect(SSEConnection.retryAfterSeconds("0") == 0)
        #expect(SSEConnection.retryAfterSeconds(" 120 ") == 120)
        let refused: [String?] = [
            nil, "", " ", "+7", "-1", "1.5", "7s", "0x10", "\u{0667}", "99999999999999999999999",
        ]
        for value in refused {
            #expect(SSEConnection.retryAfterSeconds(value) == nil, "\(String(describing: value))")
        }
    }

    /// One request through a session whose only protocol is the stub, which answers with the
    /// status and header the request's query names.
    private static func connect(status: Int, retryAfter: String?) async throws -> SSEConnection {
        var components = URLComponents(string: "https://memos.example.invalid/api/events")!
        var items = [URLQueryItem(name: "status", value: String(status))]
        if let retryAfter { items.append(URLQueryItem(name: "retryAfter", value: retryAfter)) }
        components.queryItems = items
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RetryAfterStubProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let transport = URLSessionSSETransport(session: session)
        return try await transport.connect(
            URLRequest(url: try #require(components.url)),
            under: .unfenced
        )
    }
}

final class RetryAfterStubProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
            let status = items.first(where: { $0.name == "status" })?.value.flatMap({ Int($0) })
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        var headers = ["Content-Type": "text/event-stream"]
        if let retryAfter = items.first(where: { $0.name == "retryAfter" })?.value {
            headers["Retry-After"] = retryAfter
        }
        guard
            let response = HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
