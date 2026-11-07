import MemosCore
import MemosOutbox
import SwiftUI

/// The memo half of a pending card (MEMNG-951): the date, the tags, one tile per file carrying
/// the ledger's ring, and the memo card's actions — each applied to the capture or disabled with
/// its reason.
struct PendingMemoHeader: View {
    let memo: PendingMemo
    let ledger: TransferLedger?
    let edit: () -> Void
    let withdraw: () -> Void
    /// A visibility the person chose for this capture, already past the widening question.
    var setVisibility: (VisibilityChange) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.tight) {
            HStack(spacing: DesignTokens.Space.tight) {
                Text(memo.date, format: .dateTime.day().month().year().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if PendingVisibility.isEditable(memo.job) {
                    PendingVisibilityMenu(job: memo.job, set: setVisibility)
                }
                actions
            }
            if !memo.tags.isEmpty {
                Text(memo.tags.map { "#\($0)" }.joined(separator: " "))
                    .font(.caption)
                    .foregroundStyle(DesignTokens.accent)
            }
            if !memo.tiles.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: DesignTokens.Space.tight) {
                        ForEach(memo.tiles) { file in
                            PendingTile(file: file, fraction: fraction(of: file))
                        }
                    }
                }
            }
        }
    }

    /// What the ledger has confirmed of this file, 0...1; the manifest's own count before the
    /// ledger has read the queue.
    private func fraction(of file: OutboxFile) -> Double {
        let projected = ledger?.job(memo.job.id)?.files.first { $0.id == file.id }
        let confirmed = projected?.bytesConfirmed ?? file.bytesConfirmed
        let size = projected?.byteSize ?? file.byteSize
        guard size > 0 else { return 0 }
        return min(1, Double(confirmed) / Double(size))
    }

    private var actions: some View {
        Menu {
            // Visibility, when it can be changed, is the menu beside this one rather than a row.
            ForEach(
                PendingMemoActions.offers(for: memo.job).filter {
                    $0.action != .visibility || $0.disabledReason != nil
                }
            ) { offer in
                Button(role: offer.action == .remove ? .destructive : nil) {
                    switch offer.action {
                    case .edit: edit()
                    case .remove: withdraw()
                    default: break
                    }
                } label: {
                    if let reason = offer.disabledReason {
                        Text(offer.action.title)
                        Text(reason)
                    } else {
                        Text(offer.action.title)
                    }
                }
                .disabled(offer.disabledReason != nil)
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .accessibilityLabel("Actions")
        }
    }
}

/// The edit sheet's visibility menu on a capture that has not reached the server (MEMNG-971), on
/// its pending card and in the Transfers sheet alike. A pick is decided by `PendingVisibility.pick`
/// — a narrowing goes, a widening puts its one question up — and the yes is claimed synchronously
/// in `WideningAsk.answer`, so two taps on it are one change.
struct PendingVisibilityMenu: View {
    let job: UploadJob
    let set: (VisibilityChange) -> Void
    @State private var widening = WideningAsk()

    var body: some View {
        VisibilityMenu(
            selection: Binding(
                get: { PendingVisibility.current(of: job) },
                set: { picked in
                    guard let picked else { return }
                    if let change = PendingVisibility.pick(picked, on: job, asking: &widening) {
                        set(change)
                    }
                }
            ),
            accountDefault: nil,
            spelling: .glyph,
            offersDefault: false
        )
        .alert(
            widening.title,
            isPresented: WideningAsk.presented($widening),
            presenting: widening.pending
        ) { pending in
            Button("Make \(pending.question.to.label)") {
                if let yes = widening.answer(pending, confirmed: true) { set(yes.change) }
            }
            Button("Cancel", role: .cancel) { _ = widening.answer(pending, confirmed: false) }
        } message: { pending in
            Text(pending.question.sentence)
        }
    }
}

/// A placeholder for one file of a pending memo, with the share of it the server has confirmed.
struct PendingTile: View {
    let file: OutboxFile
    let fraction: Double

    var body: some View {
        RoundedRectangle(cornerRadius: DesignTokens.Radius.card / 2)
            .fill(.quaternary)
            .frame(width: 56, height: 56)
            .overlay {
                ZStack {
                    Circle().stroke(.tertiary, lineWidth: 3)
                    Circle()
                        .trim(from: 0, to: fraction)
                        .stroke(
                            DesignTokens.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 24, height: 24)
            }
            .accessibilityElement()
            .accessibilityLabel(file.filename)
            .accessibilityValue("\(Int((fraction * 100).rounded())) percent sent")
    }
}
