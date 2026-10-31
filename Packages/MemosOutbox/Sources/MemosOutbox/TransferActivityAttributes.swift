#if canImport(ActivityKit) && os(iOS)
import ActivityKit
import Foundation

/// The transfers Live Activity's attributes, shared by the app that starts it and the widget
/// extension that draws it. It lives here because the extension links this package and nothing
/// else. Its one fixed attribute is when it started, which a relaunched app reads back to keep
/// counting the eight-hour ceiling from then; everything it shows is the content state. iOS
/// only — ActivityKit is not there for the macOS build this package also has.
public struct TransferActivityAttributes: ActivityAttributes, Sendable {
    public typealias ContentState = TransferActivityState

    public var startedAt: Date

    public init(startedAt: Date) {
        self.startedAt = startedAt
    }
}
#endif
