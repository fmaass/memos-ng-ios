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
}

/// The vocabulary, as values a test can compare. `SensoryFeedback` is an opaque SDK type; this
/// is the same choice, said in terms the assertions can hold.
public enum FeedbackKind: Equatable, Sendable, CaseIterable {
    case success
    case error
    case warning
    case lightImpact
    case mediumImpact
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
        }
    }

    public var feedback: SensoryFeedback { kind.feedback }
}

extension FeedbackKind {
    public var feedback: SensoryFeedback {
        switch self {
        case .success: .success
        case .error: .error
        case .warning: .warning
        case .lightImpact: .impact(weight: .light)
        case .mediumImpact: .impact(weight: .medium)
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
