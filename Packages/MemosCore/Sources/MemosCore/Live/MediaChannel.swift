import Foundation
import MemosAPI

/// Where the app is, as far as a live connection is concerned.
///
/// Declared here rather than taken as SwiftUI's `ScenePhase` so this layer keeps its dependencies —
/// the mapping from the real scene phase is one function in the layer that has SwiftUI, and it is
/// tested there.
public enum MediaChannelPhase: Sendable, Equatable {
    case active
    case inactive
    case background
}

/// The app's side of the live media channel: when it runs, what it reconciles when it starts, and
/// what one event does to the timeline.
///
/// The waiting has to end without anybody doing anything. A memo is created before its pictures are
/// derived — the server accepts the upload, links it, and its worker produces the thumbnail and the
/// preview afterwards — so a memo posted a moment ago carries attachments that are real, intact and
/// simply not rendered yet, and the tile shows a WAITING treatment until something says otherwise.
/// Until this, the only thing that ever said otherwise was a poll, and before that, pulling the
/// timeline down by hand.
///
/// Every decision here is a plain function over values, so the schedule of a real connection never
/// has to be waited out to assert what the app does with one.
public enum MediaChannel {

    // MARK: - when it runs

    /// Whether the channel should be open at all.
    ///
    /// Foreground and signed in, and nothing else. The two reasons are different: signed out there
    /// is no credential to present (the client would answer `.stopped(.signedOut)` and stay
    /// stopped), and in the background there is nothing on screen for an event to change — the
    /// server ends an idle stream by itself (memos-ng `app/routers/assets.py:763-764`), so holding
    /// one open there buys a wake-up per reconnect and no visible update.
    ///
    /// `inactive` KEEPS it running. That phase is the app switcher, a notification shade, an
    /// incoming call — moments the app comes straight back from, and tearing the connection down
    /// and building it up again across each of them is churn for its own sake.
    ///
    /// `hasTimeline` is the third condition and not a detail of the caller: events are applied to
    /// the loaded timeline, so a channel opened before that store exists has nowhere to put what
    /// it receives. Keeping it IN the rule is also what makes the decision safe to key a task on —
    /// the store appears once, asynchronously, and the key changing is what starts the channel
    /// then, instead of an assumption about which of two sibling tasks SwiftUI runs first.
    public static func shouldRun(
        phase: MediaChannelPhase,
        signedIn: Bool,
        hasTimeline: Bool
    ) -> Bool {
        guard signedIn, hasTimeline else { return false }
        switch phase {
        case .active, .inactive: return true
        case .background: return false
        }
    }

    // MARK: - what the stream cannot say

    /// The memos to re-read once when the channel starts — the ONE thing the poll did that events
    /// cannot, and the only piece of it that outlives it.
    ///
    /// `media_event_stream` keeps its `watching` set per CONNECTION and synthesises the `ready`
    /// event from a uid DROPPING OUT of the snapshot that same connection took a moment earlier
    /// (memos-ng `app/routers/assets.py:735-762`). A uid that was already ready when the connection
    /// opened is in no snapshot, so it drops out of nothing and is never mentioned — not on this
    /// connection and not on any later one. An upload that finished while the app was in the
    /// background is exactly that case, and it is the common one: post a photo, put the phone away,
    /// come back.
    ///
    /// So at EVERY connection open — not once per channel — the memos still SHOWING a waiting tile
    /// are re-read once through the same `refreshMemo` the poll used. Per connection is the whole
    /// point: this client reconnects after each idle close, and an attachment that is created AND
    /// finished inside one of those gaps appears in no connection's snapshot at all, so a single
    /// pass taken when the channel started would predate it and nothing later would mention it.
    ///
    /// Reconciling AT the open rather than before it also closes the narrower version of the same
    /// hole: the server takes its first snapshot as the connection opens, so a read issued after
    /// that point sees anything the snapshot already considers finished.
    ///
    /// One pass each time, not a loop: from the open onwards the stream reports the rest, and a
    /// timeline with nothing waiting costs nothing at all — which is why a cold launch, whose
    /// timeline is still empty, asks for nothing.
    public static func uidsToReconcile(in memos: [Memo]) -> [String] {
        memos.filter(\.isAwaitingTiers).map(\.uid)
    }

    /// Runs one such pass.
    @MainActor
    public static func reconcile(
        _ store: TimelineStore,
        using client: any APIProtocol,
        baseURL: URL
    ) async {
        for uid in uidsToReconcile(in: store.memos) {
            guard !Task.isCancelled else { return }
            await store.refreshMemo(uid: uid, using: client, baseURL: baseURL)
        }
    }

    // MARK: - consuming the stream

    /// Applies the channel to the timeline until it stops or the consuming task is cancelled.
    ///
    /// Leaving this loop is what closes the connection — `MediaEventClient.stream()` cancels its
    /// run on termination — so returning IS the teardown, and there is nothing else to unwind.
    ///
    /// Every event goes through `eventIfCurrent(for:)`, which is the only way one leaves its
    /// envelope: an attachment uid means nothing across accounts, and the check has to be made on
    /// the actor that owns the clock, at the moment the answer is used. Here.
    ///
    /// Connection states are read and deliberately not SHOWN. A reconnect, a backoff wait and the
    /// idle gap between two connections are all ordinary — the server ends a stream as soon as
    /// nothing is in flight — and putting any of them on screen would be a timeline that flickers
    /// a status at a reader roughly every fifteen seconds for no reason they could act on. Two of
    /// them still change what this does:
    ///
    /// - `.open` reconciles, every time. The reasoning is `uidsToReconcile`'s: each connection
    ///   watches only what its own snapshot held, so every reconnect opens a fresh blind spot over
    ///   whatever finished while nothing was connected. It costs nothing when nothing is waiting.
    /// - `.stopped` is terminal for every reason it carries: nothing here is fixed by trying
    ///   again, so the consumer goes away and the app opens a fresh channel the next time it is
    ///   signed in and in front of somebody.
    ///
    /// The reconcile is awaited in line. Events that arrive during it are not lost — the channel
    /// buffers without bound — and one that lands after it cannot undo it, because an in-flight
    /// event never applies to an attachment the re-read already found finished.
    @MainActor
    public static func consume(
        _ stream: AsyncStream<MediaEventStreamItem>,
        into store: TimelineStore,
        using client: any APIProtocol,
        baseURL: URL,
        identity: MediaIdentity = .shared
    ) async {
        for await item in stream {
            switch item {
            case .state(let state):
                switch state {
                case .open:
                    await reconcile(store, using: client, baseURL: baseURL)
                case .stopped:
                    return
                case .connecting, .waiting:
                    break
                }
            case .event(let envelope):
                guard let event = envelope.eventIfCurrent(for: identity) else { continue }
                store.apply(event)
            }
        }
    }
}
