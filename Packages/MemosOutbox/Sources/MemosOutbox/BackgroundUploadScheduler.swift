import Foundation

/// How one whole-file task ended, as the upload session reports it — possibly in a process that
/// was launched only to hear about it.
public struct WholeAnswer: Sendable, Equatable {
    public var taskIdentifier: Int
    /// What the task was for, read from its description. The launch and epoch in it say which
    /// credential the answer is evidence about.
    public var identity: WholeTaskIdentity
    /// nil when the task ended without a response: no network, cancelled, the process swiped away.
    public var statusCode: Int?
    public var body: Data
    public var errorDescription: String?

    public init(
        taskIdentifier: Int,
        identity: WholeTaskIdentity,
        statusCode: Int?,
        body: Data = Data(),
        errorDescription: String? = nil
    ) {
        self.taskIdentifier = taskIdentifier
        self.identity = identity
        self.statusCode = statusCode
        self.body = body
        self.errorDescription = errorDescription
    }
}

/// Who is told when a whole-file task finishes.
public protocol WholeAnswerHandling: Sendable {
    func handle(_ answer: WholeAnswer) async
    /// A task this lane cannot read has ended. It answers nothing, but it was holding every file
    /// back (`OutboxEngine.carriedFiles`), and its end is what releases them.
    func unreadableTaskEnded() async
}

/// Which tasks have ended, as their terminal callbacks said.
///
/// Lock-backed because the delegate records here on the session's own thread, synchronously, and
/// the scheduler reads it from its actor: a task's end must be visible the instant the callback
/// runs, not after a hop the scheduler's question could overtake.
final class TaskTerminations: @unchecked Sendable {
    private let lock = NSLock()
    private var ended: Set<Int> = []
    private var observer: (@Sendable (Int) -> Void)?

    func signal(_ taskIdentifier: Int) {
        let observer: (@Sendable (Int) -> Void)? = lock.withLock {
            ended.insert(taskIdentifier)
            return self.observer
        }
        observer?(taskIdentifier)
    }

    func hasEnded(_ taskIdentifier: Int) -> Bool {
        lock.withLock { ended.contains(taskIdentifier) }
    }

    func observe(_ observer: @escaping @Sendable (Int) -> Void) {
        lock.withLock { self.observer = observer }
    }
}

/// The upload session's delegate.
///
/// `@unchecked Sendable` with a lock for the reason the chunk lane's delegate is: URLSession calls
/// it on its own queue, from a process that may have been launched for this callback alone, so what
/// it collects cannot live in an actor it would have to await.
///
/// Public because this class IS the seam between the URL loading system and whatever applies the
/// answers, and `MemosOutboxTests` drives it through the entry points the callbacks use.
public final class UploadSessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var bodies: [Int: Data] = [:]
    /// Every task whose terminal answer has been taken, by identifier. A one-shot answer can reach
    /// here more than once — a success and a terminal failure for the same task — and exactly one
    /// may win, decided HERE, before any hop: hops do not keep their order.
    private var claimed: Set<Int> = []
    private var handler: (any WholeAnswerHandling)?
    /// Answers delivered before anything was attached, in arrival order. The session exists from
    /// launch and can answer in the same turn, before the handler is wired; an answer dropped there
    /// is a finished upload sent a second time.
    private var waiting: [WholeAnswer] = []
    /// True while `attach` is draining `waiting`. An answer arriving then joins the END of the
    /// queue the drain is working through rather than going straight to the handler, where it
    /// could overtake an older answer for the same file still being replayed.
    private var replaying = false
    /// What is still being applied. The system's completion handler waits on this.
    private let pending = PendingHandlerWork()
    /// The replace barrier's evidence: every terminal callback lands here, cancelled ones and ones
    /// whose description cannot be read included.
    let terminations = TaskTerminations()
    /// Where "finished" is reported; nil is the process-wide box the app delegate stores into.
    private let completion: OutboxBackgroundCompletion?

    public init(completion: OutboxBackgroundCompletion? = nil) {
        self.completion = completion
        super.init()
    }

    /// AWAITS the replay, so nothing that starts after adoption returns can overtake an answer the
    /// session delivered before it. Answers that arrive while it runs are drained by the same loop,
    /// behind the ones already waiting, so the order they reached this delegate is the order they
    /// are handled in.
    public func attach(_ handler: any WholeAnswerHandling) async {
        lock.withLock {
            self.handler = handler
            replaying = true
        }
        while true {
            let next: WholeAnswer? = lock.withLock {
                guard !waiting.isEmpty else {
                    replaying = false
                    return nil
                }
                return waiting.removeFirst()
            }
            guard let next else { return }
            await handler.handle(next)
            pending.leave()
        }
    }

    /// The body only accumulates; nothing is decided until the task's terminal callback.
    public func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data
    ) {
        lock.withLock { bodies[dataTask.taskIdentifier, default: Data()].append(data) }
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        complete(
            taskIdentifier: task.taskIdentifier,
            taskDescription: task.taskDescription,
            statusCode: (task.response as? HTTPURLResponse)?.statusCode,
            errorDescription: error?.localizedDescription
        )
    }

    /// A task's terminal answer, from the callback above or from a test driving the same path.
    ///
    /// The claim is taken under the lock, synchronously, before the answer goes anywhere: the
    /// first call for an identifier wins, and every later one returns false having done nothing.
    /// - Returns: whether this call's answer was the one taken.
    @discardableResult
    public func complete(
        taskIdentifier: Int,
        taskDescription: String?,
        statusCode: Int?,
        errorDescription: String?
    ) -> Bool {
        let body: Data? = lock.withLock {
            guard claimed.insert(taskIdentifier).inserted else { return nil }
            return bodies.removeValue(forKey: taskIdentifier) ?? Data()
        }
        guard let body else { return false }
        terminations.signal(taskIdentifier)
        // A task this lane cannot read has nothing to apply its answer to. It still ended, which
        // the line above has already said.
        guard let identity = WholeTaskIdentity(taskDescription: taskDescription) else {
            // It answers nothing, but it was holding every file back, and nothing else will say
            // that it has stopped. Unattached, there is nothing to tell: adoption drains anyway.
            let handler: (any WholeAnswerHandling)? = lock.withLock { self.handler }
            if let handler {
                pending.enter()
                Task {
                    await handler.unreadableTaskEnded()
                    pending.leave()
                }
            }
            return true
        }
        deliver(
            WholeAnswer(
                taskIdentifier: taskIdentifier,
                identity: identity,
                statusCode: statusCode,
                body: body,
                errorDescription: errorDescription
            )
        )
        return true
    }

    /// One claimed answer, handed on — or held until something is attached.
    public func deliver(_ answer: WholeAnswer) {
        // Counted BEFORE anything else: the session can say "no more events" in the very next
        // callback, and the system must not be answered until this has been applied.
        pending.enter()
        let handler: (any WholeAnswerHandling)? = lock.withLock {
            guard let attached = self.handler, !replaying else {
                waiting.append(answer)
                return nil
            }
            return attached
        }
        guard let handler else { return }
        Task {
            await handler.handle(answer)
            pending.leave()
        }
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let completion = completion
        pending.onDrained {
            Task { @MainActor in
                (completion ?? .shared).sessionFinished(for: OutboxUploadSession.identifier)
            }
        }
    }
}

/// What a replacement sends. It is built by the caller's closure, which `replace` invokes only
/// once the task it replaces has ended AND the replacement's authority holds — so whatever the
/// caller writes to produce it, a bumped attempt term included, is written at that moment and not
/// while the old task may still answer, nor under an authority already withdrawn.
public struct WholeSuccessor: Sendable {
    public var request: URLRequest
    public var file: URL
    public var ref: WholeFileRef
    public var attempt: Int
    public var epoch: Int

    public init(request: URLRequest, file: URL, ref: WholeFileRef, attempt: Int, epoch: Int) {
        self.request = request
        self.file = file
        self.ref = ref
        self.attempt = attempt
        self.epoch = epoch
    }
}

/// A successor waiting for its predecessor to end: the authority it will be sent under, the
/// closure that builds it, and the report that the replacement is over.
private struct DeferredSuccessor: Sendable {
    var authority: SendAuthority
    var build: @Sendable () async -> WholeSuccessor?
    var settled: @Sendable (WholeTask?) async -> Void = { _ in }
}

/// What `replace` did.
public enum WholeReplacement: Sendable, Equatable {
    /// The old task has ended: the successor's task, or nil when the authority did not hold (the
    /// closure was then not invoked), the closure returned nil, or the authority was withdrawn
    /// while the closure ran (whatever it wrote stands, with no task — see `replace`).
    case replaced(WholeTask?)
    /// The old task was still listed when the bound ran out. Its successor waits in memory for the
    /// task's terminal callback or its absence from a later listing (`reexamineDeferred`) — never
    /// for the clock.
    case deferred
    /// This task has already been handed to `replace`. Refused, so one task has one successor.
    case refused
}

/// The whole lane's background session: one task per file, each carrying the whole original.
///
/// Its answers go to the attached handler; what it decides on its own is only what a listing can
/// tell it — which tasks it cannot read, which carry the wrong networks, and when a cancelled task
/// has really gone.
public actor BackgroundUploadScheduler {
    /// How long `replace` waits for a cancelled task to end before it defers the successor.
    public static let replaceBound: TimeInterval = 10

    private let session: any UploadTaskSession
    private let delegate: UploadSessionDelegate
    public nonisolated let launch: UUID
    private let now: @Sendable () -> Date
    private let pause: @Sendable () async -> Void
    /// Every task handed to `replace` in this process. Identifiers are not reused within a session.
    private var replacementsClaimed: Set<Int> = []
    /// Successors whose predecessor was still listed when the bound ran out, by that predecessor.
    private var deferred: [Int: DeferredSuccessor] = [:]
    /// The tasks nobody can read that the last `cancelUnreadable` found, each until it has ended.
    /// Any one of them may be carrying any file, so while one is live no task is created at all.
    private var unreadableLive: Set<Int> = []
    private var observing = false

    public init(appGroup: String = OutboxDefaults.appGroup) {
        let delegate = UploadSessionDelegate()
        let session = URLSession(
            configuration: OutboxUploadSession.backgroundConfiguration(appGroup: appGroup),
            delegate: delegate,
            delegateQueue: nil
        )
        self.init(session: URLSessionUploadTaskSession(session: session), delegate: delegate)
    }

    /// The scheduler over a session handed in, with the clock and the pause between listings
    /// injectable, because the replace barrier's bound is a duration and a test must not sleep it.
    public init(
        session: any UploadTaskSession,
        delegate: UploadSessionDelegate = UploadSessionDelegate(),
        launch: UUID = OutboxUploadSession.processLaunch,
        now: @escaping @Sendable () -> Date = { Date() },
        pause: @escaping @Sendable () async -> Void = {
            _ = try? await Task.sleep(for: .milliseconds(250))
        }
    ) {
        self.session = session
        self.delegate = delegate
        self.launch = launch
        self.now = now
        self.pause = pause
    }

    /// Wired after construction for the reason the chunk lane's is: the handler will need the
    /// scheduler, so one of the two references has to be attached rather than passed in.
    public func attach(_ handler: any WholeAnswerHandling) async {
        await delegate.attach(handler)
    }

    /// Every task the session holds, raw: readable or not, whatever process created it.
    public func tasks() async -> [WholeTaskListing] {
        await session.allTasks()
    }

    /// Hands one file to the session, whole.
    ///
    /// The authority is asked HERE, on the executor that creates the task, with nothing awaited
    /// between its answer and the task: a task handed to the background session outlives this
    /// process and cannot be taken back, and the hop that reached this executor is a suspension an
    /// account switch fits into. This process's launch and the epoch the request presented go into
    /// the description before the task starts.
    /// - Returns: the task, or nil when the authority no longer held and nothing was created.
    public func upload(
        _ request: URLRequest,
        fromFile file: URL,
        for ref: WholeFileRef,
        attempt: Int,
        under authority: SendAuthority,
        issuedUnder epoch: Int
    ) -> WholeTask? {
        // The one place every task is created — a first hand-off, a retry and a replacement's
        // successor alike — so the barrier is asked here, synchronously, beside the authority.
        guard unreadableLive.allSatisfy({ delegate.terminations.hasEnded($0) }) else { return nil }
        guard authority.holds() else { return nil }
        let identity = WholeTaskIdentity(
            jobID: ref.jobID, fileID: ref.fileID, attempt: attempt, launch: launch, epoch: epoch
        )
        let taskIdentifier = session.uploadTask(
            with: request, fromFile: file, description: identity.taskDescription
        )
        return WholeTask(taskIdentifier: taskIdentifier, identity: identity)
    }

    /// Asks the session to cancel these tasks. A cancel is a request, not a barrier: a task whose
    /// file is sent again goes through `replace`.
    public func cancel(_ taskIdentifiers: [Int]) async {
        for id in taskIdentifiers {
            await session.cancel(taskIdentifier: id)
        }
    }

    /// Cancels every task whose description this lane cannot read, and names them. Left alone, such
    /// a task keeps sending a file nobody is waiting for.
    public func cancelUnreadable() async -> [Int] {
        var cancelled: [Int] = []
        for task in await session.allTasks()
        where WholeTaskIdentity(taskDescription: task.taskDescription) == nil {
            await session.cancel(taskIdentifier: task.taskIdentifier)
            cancelled.append(task.taskIdentifier)
        }
        // Replaced, not added to: a task gone from this listing has left the session.
        unreadableLive = Set(cancelled)
        return cancelled
    }

    /// The readable tasks still able to send whose original request allows other networks than
    /// the person's choice does now — read from the session, so a task a previous launch created
    /// is judged by the flags it actually carries. A task whose request the session does not list
    /// cannot be shown to match, and is named too.
    public func mismatched(allowsMobileData: Bool) async -> [WholeTask] {
        let wanted = WholeTaskNetworkAccess.policy(allowsMobileData: allowsMobileData)
        let listed = await session.allTasks()
        return listed.compactMap { task in
            guard task.state == .running || task.state == .suspended,
                task.access != wanted,
                let identity = WholeTaskIdentity(taskDescription: task.taskDescription)
            else { return nil }
            return WholeTask(taskIdentifier: task.taskIdentifier, identity: identity)
        }
    }

    /// Cancels a task and sends its successor only once the task has ENDED.
    ///
    /// A cancel is asynchronous, so elapsed time proves nothing: two uploads of one file must never
    /// overlap. The task has ended when its terminal callback has arrived or a fresh listing no
    /// longer holds it. Up to `replaceBound` is spent asking; after that the successor is deferred,
    /// and goes when the terminal callback arrives or `reexamineDeferred` finds the task gone.
    /// A second call for a task already handed here is refused.
    ///
    /// What is guaranteed about `successor`: it is invoked at most once, only after the old task
    /// has ended, and only when `authority.holds()` answered true on this actor immediately before
    /// — a withdrawn authority never has it build anything. The closure may itself suspend (it
    /// writes the bumped term), so the authority is asked AGAIN at the send; a withdrawal inside
    /// the closure leaves what it wrote with no task, the state a kill between that write and the
    /// send leaves, which reconciliation already reads as a file nothing carries.
    public func replace(
        _ task: WholeTask,
        under authority: SendAuthority,
        successor: @escaping @Sendable () async -> WholeSuccessor?
    ) async -> WholeReplacement {
        await replace(task, under: authority, onSettled: { _ in }, successor: successor)
    }

    /// `replace`, reporting through `onSettled` when the replacement is over: after the successor's
    /// task has been created, with that task, or with nil once no successor will be — the
    /// authority withdrawn, the closure returning nil, or the call refused. Exactly once for every
    /// call, a deferred one included, whose report waits for its send. A caller that keeps a file
    /// from being sent again for the span of a replacement releases it there, so the interval
    /// between the closure's write and the task's creation is covered as well as the deferral.
    public func replace(
        _ task: WholeTask,
        under authority: SendAuthority,
        onSettled: @escaping @Sendable (WholeTask?) async -> Void,
        successor: @escaping @Sendable () async -> WholeSuccessor?
    ) async -> WholeReplacement {
        let id = task.taskIdentifier
        guard replacementsClaimed.insert(id).inserted else {
            await onSettled(nil)
            return .refused
        }
        let pending = DeferredSuccessor(authority: authority, build: successor, settled: onSettled)
        await session.cancel(taskIdentifier: id)
        guard await hasEnded(id) else {
            deferred[id] = pending
            observeTerminations()
            // A terminal callback that landed after the last look found nothing deferred to act
            // on. It is on record, so look once more.
            if delegate.terminations.hasEnded(id), let late = deferred.removeValue(forKey: id) {
                return .replaced(await send(late))
            }
            return .deferred
        }
        return .replaced(await send(pending))
    }

    /// Sends each deferred successor whose predecessor has since ended or left the session's list.
    ///
    /// The candidates are fixed BEFORE the listing is awaited. A listing is evidence only about the
    /// tasks that existed when it was taken, and the actor is free while it is awaited: a task
    /// deferred in that window may have been created after the listing, and its absence from it
    /// would be read as its end while it is still sending. Such a task waits for the next look.
    /// - Returns: the tasks sent.
    public func reexamineDeferred() async -> [WholeTask] {
        let candidates = deferred.keys.sorted()
        guard !candidates.isEmpty else { return [] }
        let listed = Set(await session.allTasks().map(\.taskIdentifier))
        var sent: [WholeTask] = []
        for id in candidates where delegate.terminations.hasEnded(id) || !listed.contains(id) {
            guard let successor = deferred.removeValue(forKey: id) else { continue }
            if let task = await send(successor) { sent.append(task) }
        }
        return sent
    }

    private func hasEnded(_ id: Int) async -> Bool {
        let deadline = now().addingTimeInterval(Self.replaceBound)
        while true {
            if delegate.terminations.hasEnded(id) { return true }
            let listed = await session.allTasks()
            if !listed.contains(where: { $0.taskIdentifier == id }) { return true }
            if now() >= deadline { return false }
            await pause()
        }
    }

    private func observeTerminations() {
        guard !observing else { return }
        observing = true
        delegate.terminations.observe { [weak self] id in
            guard let self else { return }
            Task { await self.terminated(id) }
        }
    }

    private func terminated(_ id: Int) async {
        guard let successor = deferred.removeValue(forKey: id) else { return }
        _ = await send(successor)
    }

    /// Every successor goes out through here, and every one reports once it has, whatever happened.
    private func send(_ pending: DeferredSuccessor) async -> WholeTask? {
        let sent = await build(pending)
        await pending.settled(sent)
        return sent
    }

    private func build(_ pending: DeferredSuccessor) async -> WholeTask? {
        // Asked before anything is built, so a withdrawn authority writes nothing.
        guard pending.authority.holds() else { return nil }
        guard let next = await pending.build() else { return nil }
        return upload(
            next.request,
            fromFile: next.file,
            for: next.ref,
            attempt: next.attempt,
            under: pending.authority,
            issuedUnder: next.epoch
        )
    }
}
