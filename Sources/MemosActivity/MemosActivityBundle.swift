import ActivityKit
import MemosOutbox
import SwiftUI
import WidgetKit

/// The widget extension exists for one thing: drawing the transfers Live Activity the app starts.
/// It links the outbox and nothing else — the attributes and the content state are defined there,
/// and every number it draws is the ledger's.
@main
struct MemosActivityBundle: WidgetBundle {
    var body: some Widget {
        TransferActivityWidget()
    }
}

/// The lock-screen banner and the Dynamic Island's compact, minimal and expanded presentations.
struct TransferActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TransferActivityAttributes.self) { context in
            HStack(spacing: 12) {
                TransferRing(state: context.state)
                    .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(TransferWords.line(context.state))
                        .font(.headline)
                    Text(TransferWords.bytes(context.state))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(TransferWords.count(context.state))
                    .font(.title3.monospacedDigit())
            }
            .padding()
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    TransferRing(state: context.state)
                        .frame(width: 32, height: 32)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(TransferWords.count(context.state))
                        .font(.title3.monospacedDigit())
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(TransferWords.line(context.state))
                        .font(.subheadline)
                }
            } compactLeading: {
                TransferRing(state: context.state)
                    .frame(width: 18, height: 18)
            } compactTrailing: {
                Text(TransferWords.count(context.state))
                    .font(.caption.monospacedDigit())
            } minimal: {
                TransferRing(state: context.state)
                    .frame(width: 18, height: 18)
            }
        }
    }
}

/// The ring: the share of the queue's bytes the server has confirmed.
struct TransferRing: View {
    let state: TransferActivityState

    private var fraction: Double {
        let summary = state.summary
        guard summary.bytesTotal > 0 else { return state.status == .finished ? 1 : 0 }
        return min(1, Double(summary.bytesConfirmed) / Double(summary.bytesTotal))
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(.secondary.opacity(0.3), lineWidth: 3)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(.tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

/// The activity's words. They live with the extension because it may link nothing that holds the
/// app's own wording.
enum TransferWords {
    static func count(_ state: TransferActivityState) -> String {
        "\(state.summary.filesDone)/\(state.summary.filesTotal)"
    }

    static func bytes(_ state: TransferActivityState) -> String {
        let done = state.summary.bytesConfirmed.formatted(.byteCount(style: .file))
        let total = state.summary.bytesTotal.formatted(.byteCount(style: .file))
        return "\(done) of \(total)"
    }

    static func line(_ state: TransferActivityState) -> String {
        switch state.status {
        case .sending:
            "Sending \(min(state.summary.filesDone + 1, state.summary.filesTotal)) of "
                + "\(state.summary.filesTotal)"
        case .paused(.some(.waitingForWiFi)): "Paused · waiting for Wi-Fi"
        case .paused(.some(.noConnection)): "Paused · no connection"
        case .paused(.some(.retrying)): "Paused · trying again soon"
        case .paused(.some(.held)): "Paused · needs you"
        case .paused(.none): "Paused"
        case .finished:
            state.summary.filesDone == state.summary.filesTotal ? "Live" : "Finished"
        }
    }
}
