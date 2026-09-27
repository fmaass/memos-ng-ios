import Testing

/// One suite at a time among the suites that REPLACE the picture layer's process-wide objects —
/// `MediaRetrySignal.shared`, `MediaImageLoader.transport`, `MediaImageLoader.store`.
///
/// `.serialized` orders the tests inside one suite and nothing else, so two suites that each
/// install their own signal run side by side. A tile observes the signal that was `shared` when
/// its body last ran; a suite replacing it underneath another suite's hosted screen leaves that
/// suite publishing on an object none of its tiles is watching, and a case asserting that no tile
/// asked again then passes whether or not the tiles are there. Every suite that replaces one of
/// those objects carries this trait.
struct MediaGlobalsTrait: SuiteTrait, TestScoping {
    /// Scoped at the suite, so a whole suite holds the gate and its own serialized tests run under
    /// it one after another. Taken per test instead, two suites' tests could still interleave.
    func scopeProvider(for test: Test, testCase: Test.Case?) -> Self? {
        test.isSuite ? self : nil
    }

    func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @concurrent @Sendable () async throws -> Void
    ) async throws {
        await MediaGlobalsGate.shared.enter()
        do {
            try await function()
        } catch {
            await MediaGlobalsGate.shared.leave()
            throw error
        }
        await MediaGlobalsGate.shared.leave()
    }
}

extension Trait where Self == MediaGlobalsTrait {
    static var mediaGlobals: Self { Self() }
}

/// A first-come, first-served gate held across suspension points. An actor alone is not one: it
/// admits another caller at every `await` inside it.
private actor MediaGlobalsGate {
    static let shared = MediaGlobalsGate()

    private var held = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        guard held else {
            held = true
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    /// Hands the gate straight to the next suite in line, so nobody arriving in between can take
    /// it first.
    func leave() {
        guard !waiting.isEmpty else {
            held = false
            return
        }
        waiting.removeFirst().resume()
    }
}
