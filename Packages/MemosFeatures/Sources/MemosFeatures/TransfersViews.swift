import MemosCore
import MemosOutbox
import SwiftUI

/// The slim line above the timeline's first card while anything is queued, and for thirty seconds
/// after the last capture lands. It lives in the list, under the pull-to-refresh, and never in the
/// bar (ADR-0008). A tap opens the transfers sheet.
///
/// Whether its row is in the list is the timeline's call (`TransfersStripPlace`, fed by
/// `TransfersStripWatch`): a strip kept there while the reader is away from the top still has a
/// line to say.
struct TransfersStrip: View {
    let ledger: TransferLedger
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: DesignTokens.Space.snug) {
                Image(systemName: ledger.jobs.isEmpty ? "checkmark.circle" : "arrow.up.circle")
                Text(TransfersPresentation.shownLine(for: ledger, now: Date()))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.vertical, DesignTokens.Space.snug)
            .padding(.horizontal, DesignTokens.Space.regular)
            .background(.quaternary.opacity(0.5), in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Shows every upload")
    }
}

/// Reports whether the ledger wants a strip, from outside the list's rows: a row that is not in
/// the list cannot watch for the moment it should be. It sets no repeating timer: it is read again
/// when the ledger changes, and once more at the instant a lingering strip goes.
struct TransfersStripWatch: View {
    let ledger: TransferLedger
    let enabled: Bool
    let report: (Bool) -> Void

    /// Written when the linger runs out, so the body is read again and finds the strip gone.
    @State private var armedAt = Date()

    var body: some View {
        let wanted = enabled && ledger.isStripVisible(at: Swift.max(Date(), armedAt))
        Color.clear
            .onChange(of: wanted, initial: true) { _, wanted in report(wanted) }
            .task(id: ledger.stripHidesAt) {
                guard let hidesAt = ledger.stripHidesAt else { return }
                let wait = hidesAt.timeIntervalSince(Date())
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                guard !Task.isCancelled else { return }
                armedAt = hidesAt
            }
    }
}

/// Every queued capture, a row per file: a ring, the bytes the server has confirmed, the one-line
/// reason when the file is not moving, and the one fix a stopped row offers.
struct TransfersSheet: View {
    let ledger: TransferLedger
    let lastProgressAt: [UUID: Date]
    let verdict: UploadVerdict
    let perform: (TransfersAction, UUID) -> Void
    /// A visibility chosen for a capture that has not landed, for its manifest (MEMNG-971).
    var setVisibility: (UUID, VisibilityChange) -> Void = { _, _ in }
    @Environment(\.dismiss) private var dismiss
    /// Written when the next row's stall threshold passes, so the body is read again and that row
    /// says it has stopped — one wake at the instant a sentence changes, never a repeating timer.
    @State private var wokeAt = Date.distantPast

    var body: some View {
        let now = Swift.max(Date(), wokeAt)
        let sections = TransfersPresentation.sections(
            for: ledger, now: now, lastProgressAt: lastProgressAt, verdict: verdict)
        let stall = TransfersPresentation.sheetWake(
            for: ledger, lastProgressAt: lastProgressAt, after: now)
        NavigationStack {
            List {
                if sections.isEmpty {
                    Text(TransfersPresentation.nothingLeft)
                        .foregroundStyle(.secondary)
                }
                ForEach(sections) { section in
                    Section {
                        ForEach(section.rows) { row in
                            TransfersRowView(row: row) { action in
                                perform(action, row.jobID)
                            }
                        }
                    } header: {
                        HStack {
                            Text(section.title.isEmpty ? "Capture" : section.title)
                            Spacer(minLength: 0)
                            if let job = ledger.job(section.id)?.manifest,
                                PendingVisibility.isEditable(job)
                            {
                                PendingVisibilityMenu(job: job) { setVisibility(section.id, $0) }
                            }
                        }
                    }
                }
            }
            .task(id: stall) {
                guard let stall else { return }
                let wait = stall.timeIntervalSince(Date())
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                guard !Task.isCancelled else { return }
                wokeAt = stall
            }
            .navigationTitle("Transfers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

struct TransfersRowView: View {
    let row: TransfersRow
    let act: (TransfersAction) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: DesignTokens.Space.regular) {
            TransferRing(fraction: row.fraction)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: DesignTokens.Space.tight) {
                Text(row.filename)
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(row.bytes)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                if let reason = row.reason {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if let action = row.action {
                    Button(action.title) { act(action) }
                        .font(.footnote)
                        .buttonStyle(.bordered)
                        .tint(DesignTokens.accent)
                }
            }
        }
        .padding(.vertical, DesignTokens.Space.tight)
    }
}

/// The ring: the share of the file the server has confirmed.
struct TransferRing: View {
    let fraction: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(.quaternary, lineWidth: 3)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(DesignTokens.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .accessibilityElement()
        .accessibilityLabel("\(Int((fraction * 100).rounded())) percent confirmed")
    }
}
