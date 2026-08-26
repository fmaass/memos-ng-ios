import SwiftUI

/// The activity heatmap, as the timeline's own scrollable header.
///
/// It sits above the first day group and folds away behind a disclosure, because a card that a
/// reader cannot put away is a card that crowds the feed it is supposed to introduce.
///
/// The squares are deliberately NOT tappable: the web client's cells are inert `<span>`s and this
/// is the parity port of them. `HeatCell` already carries the day a tap would need, so the loupe
/// that turns the heatmap into a date axis (MEMNG-120) adds a gesture, not a model.
struct HeatmapCard: View {
    let grid: HeatmapGrid
    @Binding var expanded: Bool

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
                HeatmapGridView(grid: grid)
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
        // One element for the whole grid. A rotor that stops on eighty-four unlabelled squares is
        // worse than one that stops on none, so the card says what it amounts to instead.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(grid.summary)
    }

    /// A day, or the empty slot a short trailing column leaves behind — drawn as nothing at all
    /// rather than as a zero-count day, which would claim a day that has not happened yet.
    @ViewBuilder
    private func square(row: Int, of column: [HeatCell]) -> some View {
        if column.indices.contains(row) {
            let cell = column[row]
            RoundedRectangle(cornerRadius: DesignTokens.Space.hair, style: .continuous)
                .fill(Self.fill(for: cell.level))
                .overlay {
                    if cell.isToday {
                        RoundedRectangle(cornerRadius: DesignTokens.Space.hair, style: .continuous)
                            .strokeBorder(.primary, lineWidth: 1)
                    }
                }
        } else {
            Color.clear
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
