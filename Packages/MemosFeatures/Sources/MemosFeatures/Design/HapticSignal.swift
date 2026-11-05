import MemosCore
import SwiftUI

/// What the phone should say with its Taptic Engine about something that just happened.
///
/// Wiring haptics straight into a view body means the mapping — which act feels like what, and
/// which acts feel like nothing at all — lives somewhere no test can reach. So the ACT is named
/// here and the mapping is a pure table, asserted case by case: a destructive act that started
/// feeling like a success is exactly the kind of regression no screenshot would ever show.
public enum MemoAct: Equatable, Sendable, CaseIterable {
    case posted
    case postFailed
    case pinned
    case unpinned
    case deleted
    case taskChecked
    case taskUnchecked
    /// The scrubbing finger has crossed onto another day.
    case dayScrubbed
}

/// The vocabulary, as values a test can compare. `SensoryFeedback` is an opaque SDK type; this
/// is the same choice, said in terms the assertions can hold.
public enum FeedbackKind: Equatable, Sendable, CaseIterable {
    case success
    case error
    case warning
    case lightImpact
    case mediumImpact
    /// The tick a picker wheel makes as it passes a value — one per step, never a pattern.
    case selection
}

extension MemoAct {
    /// Pin and unpin are the same physical act in two directions, so they share the lightest tick.
    /// Posting is the only success worth the full success pattern — it is what the app is for —
    /// and deleting is a WARNING, not a success, because it is the one act on this screen that
    /// cannot be taken back.
    public var kind: FeedbackKind {
        switch self {
        case .posted: .success
        case .postFailed: .error
        case .deleted: .warning
        case .pinned, .unpinned, .taskUnchecked: .lightImpact
        case .taskChecked: .mediumImpact
        // A scrub crosses dozens of days in one gesture, so its tick has to be the lightest
        // thing the engine can say: an impact per cell would be a rumble, not feedback.
        case .dayScrubbed: .selection
        }
    }

    public var feedback: SensoryFeedback { kind.feedback }
}

extension MemoAct {
    /// The act a save's answer is felt as, or nil for none. A question (`.ask`) is not a failure:
    /// nothing went, the sheet asks it as it asks any widening, and an error buzz under that
    /// question would say the opposite (MEMNG-1033).
    public static func of(_ outcome: ComposeOutcome) -> MemoAct? {
        switch outcome {
        case .saved: .posted
        case .failed: .postFailed
        case .ask: nil
        }
    }
}

extension FeedbackKind {
    public var feedback: SensoryFeedback {
        switch self {
        case .success: .success
        case .error: .error
        case .warning: .warning
        case .lightImpact: .impact(weight: .light)
        case .mediumImpact: .impact(weight: .medium)
        case .selection: .selection
        }
    }
}

/// A value a view can bump to drive `sensoryFeedback(trigger:)`, carrying WHICH act fired.
///
/// The act alone is not enough: pinning twice in a row would not change the value, and the second
/// tap would be silent. The count is what makes a repeat of the same act a new event.
public struct MemoFeedbackTrigger: Equatable, Sendable {
    public private(set) var act: MemoAct?
    public private(set) var count: Int

    public init() {
        self.act = nil
        self.count = 0
    }

    public mutating func fire(_ act: MemoAct) {
        self.act = act
        self.count += 1
    }
}
