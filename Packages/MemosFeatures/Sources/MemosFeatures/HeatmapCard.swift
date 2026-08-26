import MemosCore
import SwiftUI

/// The activity heatmap, as the search sheet's empty-query state.
///
/// It opened the TIMELINE until MEMNG-126. It reads better here and it costs less: the sheet is
/// where a date is looked for, and a card the timeline was headed by put a second request in front
/// of every pull of the list (MEMNG-166) for something a reader was not asking for.
///
/// It folds away behind a disclosure, because a card that a reader cannot put away is a card that
/// crowds whatever it is introducing.
///
/// The squares are tappable only when the sheet hands it somewhere to go: `jump` is what turns a
/// day into a control, and `HeatmapDateJump` decides which days are ones. The web client's cells
/// are inert `<span>`s, so a heatmap drawn with no `jump` is still the parity port of them.
struct HeatmapCard: View {
    let grid: HeatmapGrid
    @Binding var expanded: Bool
    /// Where a tapped day goes, or nil for a heatmap that is only a picture.
    var jump: ((MemoQueryAnchor) -> Void)?
    /// Whether the counts are the server's answer or the absence of one.
    ///
    /// It defaults to `.ready` because everything that is not the search sheet already has its
    /// counts by the time it draws this. Waiting, the grid is drawn greyed and inert, at exactly
    /// the size it will be — the geometry is twelve weeks either way, so nothing under it moves
    /// when the counts land (MEMNG-176) — and it does not claim there were no memos (MEMNG-175).
    var phase: SearchSectionPhase = .ready

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.snug) {
            Button {
                withAnimation(.snappy) { expanded.toggle() }
            } label: {
                HeatmapHeader(expanded: expanded)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Activity")
            .accessibilityValue(expanded ? "Shown" : "Hidden")
            .accessibilityHint("Shows or hides the activity heatmap")

            if expanded {
                HeatmapGridView(
                    grid: grid,
                    // A placeholder day is not a control: every square is level 0 while the
                    // counts are unknown, so a tap would open the timeline at a date chosen by
                    // the absence of data.
                    jump: phase.acceptsTaps ? jump : nil,
                    summary: HeatmapPresentation.summary(for: grid, loaded: phase == .ready)
                )
                .redacted(reason: phase == .loading ? .placeholder : [])
                // The counts landing is not an animation. Keyed on the phase rather than put on
                // the card, so the disclosure above keeps its own `withAnimation(.snappy)`.
                .transaction(value: phase) { $0.disablesAnimations = true }
            }
        }
        .padding(DesignTokens.Space.regular)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: DesignTokens.Radius.card))
    }
}

/// The disclosure line. Chevron FIRST, so the row has an intrinsic width a fitting test can
/// measure — a trailing `Spacer` would make it report whatever it was offered.
struct HeatmapHeader: View {
    let expanded: Bool

    var body: some View {
        HStack(spacing: DesignTokens.Space.tight) {
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .rotationEffect(.degrees(expanded ? 90 : 0))
            Text("Activity")
                .font(.subheadline.weight(.semibold))
        }
        .foregroundStyle(.secondary)
    }
}

/// Twelve weeks of days, seven to a column, oldest column first.
struct HeatmapGridView: View {
    let grid: HeatmapGrid
    /// Where a tapped day goes. Nil draws the grid as the picture it has always been.
    var jump: ((MemoQueryAnchor) -> Void)?
    /// What the whole grid amounts to in one sentence. Handed in rather than read off the grid,
    /// because a grid with no counts in it means two different things and only the caller knows
    /// which — see `HeatmapPresentation.summary(for:loaded:)`.
    var summary: String?

    /// The square grows with the text size, because a fixed 12pt cell beside 50pt type is the
    /// defect `DesignTokens.Metric` exists to prevent — but only up to `maxSide`. Eighty-four
    /// squares at the accessibility scale factor would want a grid three times wider than any
    /// phone, so the growth stops where the narrowest card stops rather than running off it.
    @ScaledMetric(relativeTo: .caption2) private var side = DesignTokens.Metric.heatCell

    /// The widest a cell may be and still leave twelve columns inside the narrowest card this app
    /// draws: 393pt screen, less the list's own gutters and the card's padding.
    static let maxSide: CGFloat = 26
    static let gap = DesignTokens.Space.hair

    var body: some View {
        let cell = min(side, Self.maxSide)
        VStack(alignment: .leading, spacing: Self.gap) {
            ForEach(0..<HeatmapPresentation.daysPerColumn, id: \.self) { row in
                HStack(spacing: Self.gap) {
                    ForEach(grid.columns.indices, id: \.self) { column in
                        square(row: row, of: grid.columns[column])
                            .frame(width: cell, height: cell)
                    }
                }
            }
        }
        // Inert, the whole grid is ONE element: a rotor that stops on eighty-four unlabelled
        // squares is worse than one that stops on none, so the card says what it amounts to
        // instead. Tappable, the days that are controls have to be reachable, so the grid becomes
        // a container holding them — and only them, because `square` labels no other cell.
        .accessibilityElement(children: jump == nil ? .ignore : .contain)
        .accessibilityLabel(summary ?? grid.summary)
    }

    /// A day, or the empty slot a short trailing column leaves behind — drawn as nothing at all
    /// rather than as a zero-count day, which would claim a day that has not happened yet.
    ///
    /// A day is a BUTTON only where a jump would actually go somewhere, so the no-op on an empty
    /// day is the absence of a control rather than a control that does nothing: nothing highlights
    /// under the finger, and VoiceOver never offers it.
    @ViewBuilder
    private func square(row: Int, of column: [HeatCell]) -> some View {
        if column.indices.contains(row) {
            let cell = column[row]
            if let jump, case .jump(let anchor) = HeatmapDateJump.tap(on: cell) {
                Button {
                    jump(anchor)
                } label: {
                    swatch(cell)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(HeatmapDateJump.label(for: cell))
                .accessibilityHint("Opens the timeline at this day")
            } else {
                swatch(cell)
            }
        } else {
            Color.clear
        }
    }

    private func swatch(_ cell: HeatCell) -> some View {
        RoundedRectangle(cornerRadius: DesignTokens.Space.hair, style: .continuous)
            .fill(Self.fill(for: cell.level))
            .overlay {
                if cell.isToday {
                    RoundedRectangle(cornerRadius: DesignTokens.Space.hair, style: .continuous)
                        .strokeBorder(.primary, lineWidth: 1)
                }
            }
    }

    /// The five buckets. Level 0 is a system fill and the rest are the app's own accent, so both
    /// answer the light and dark question themselves rather than being painted twice.
    static func fill(for level: Int) -> AnyShapeStyle {
        switch level {
        case ..<1: AnyShapeStyle(Color(.tertiarySystemFill))
        case 1: AnyShapeStyle(DesignTokens.accent.opacity(0.28))
        case 2: AnyShapeStyle(DesignTokens.accent.opacity(0.5))
        case 3: AnyShapeStyle(DesignTokens.accent.opacity(0.74))
        default: AnyShapeStyle(DesignTokens.accent)
        }
    }
}
