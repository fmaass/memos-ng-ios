import MemosCore
import SwiftUI

/// The activity heatmap, as the search sheet's empty-query state.
///
/// It opened the TIMELINE until MEMNG-126. It reads better here and it costs less: the sheet is
/// where a date is looked for, and a card the timeline was headed by put a second request in front
/// of every pull of the list (MEMNG-166) for something a reader was not asking for.
///
/// It is shown, always. It used to fold away behind a disclosure, and a card a household folded
/// once was one it never found again: the sheet then opened as a title over a date field with
/// nothing under it to scrub, which is the opposite of what the section is for (MEMNG-192).
///
/// The squares answer to a finger only when the sheet hands it something to move: `scrubbing` is
/// what turns the grid into the date field's scrubber (MEMNG-178). The web client's cells are
/// inert `<span>`s, so a heatmap drawn without it is still the parity port of them.
struct HeatmapCard: View {
    let grid: HeatmapGrid
    /// What a finger on the grid moves, or nil for a heatmap that is only a picture.
    var scrubbing: HeatmapScrubbing?
    /// Whether the counts are the server's answer or the absence of one.
    ///
    /// It defaults to `.ready` because everything that is not the search sheet already has its
    /// counts by the time it draws this. Waiting, the grid is drawn greyed and inert, at exactly
    /// the size it will be — the geometry is twelve weeks either way, so nothing under it moves
    /// when the counts land (MEMNG-176) — and it does not claim there were no memos (MEMNG-175).
    var phase: SearchSectionPhase = .ready

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.snug) {
            HeatmapHeader()
                .frame(maxWidth: .infinity, alignment: .leading)

            HeatmapGridView(
                grid: grid,
                // A placeholder day is not a control: every square is level 0 while the
                // counts are unknown, so a scrub would move the field to a date chosen by
                // the absence of data.
                scrubbing: phase.acceptsTaps ? scrubbing : nil,
                summary: HeatmapPresentation.summary(for: grid, loaded: phase == .ready)
            )
            .redacted(reason: phase == .loading ? .placeholder : [])
            // The counts landing is not an animation.
            .transaction(value: phase) { $0.disablesAnimations = true }
        }
        .padding(DesignTokens.Space.regular)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: DesignTokens.Radius.card))
    }
}

/// The card's line, and a LABEL rather than a control since MEMNG-192 — there is nothing left to
/// disclose. It stays its own view because it is measured: the fitting test asks what the line
/// wants at the largest text size, and a line inside the card would report the card's width.
struct HeatmapHeader: View {
    var body: some View {
        Text("Activity")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}

/// Twelve weeks of days, seven to a column, oldest column first.
struct HeatmapGridView: View {
    let grid: HeatmapGrid
    /// What a finger on the grid moves. Nil draws it as the picture it has always been.
    var scrubbing: HeatmapScrubbing?
    /// What the whole grid amounts to in one sentence. Handed in rather than read off the grid,
    /// because a grid with no counts in it means two different things and only the caller knows
    /// which — see `HeatmapPresentation.summary(for:loaded:)`.
    var summary: String?

    static let gap = DesignTokens.Space.hair
    /// The grid's own coordinate space, so a drag reports where it is ON THE GRID rather than
    /// somewhere in a sheet whose offset the hit-testing would then have to know about.
    private static let space = "heatmap-grid"

    @GestureState private var scrubTouch = false

    /// The width the squares were last laid out in — the only input the geometry has (MEMNG-186).
    ///
    /// It is read back off the frame the layout RESOLVED to rather than remembered from the width
    /// that was proposed, and the two are the same number: a layout reports its own size, and this
    /// arithmetic is idempotent over it (`HeatmapGeometryTests`). So the pitch a finger is divided
    /// by is the pitch the squares were drawn on, because it is the same value.
    ///
    /// Nothing, until the first layout pass has happened — and a geometry with no square in it
    /// answers no finger at all rather than dividing one by a pitch made of the gap alone.
    @State private var laidOutWidth: CGFloat = 0

    private var geometry: HeatmapGeometry {
        HeatmapGeometry(availableWidth: laidOutWidth, of: grid, gap: Self.gap)
    }

    var body: some View {
        if let scrubbing {
            squares
                .coordinateSpace(.named(Self.space))
                // One gesture for the whole grid rather than a control per square. A tap IS a
                // drag of no distance, so `minimumDistance: 0` makes the two the same
                // interaction — and eighty-four buttons would each want the touch a scrub needs
                // to keep travelling through.
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
                        .onChanged { value in
                            guard
                                let cell = HeatmapScrub.cell(
                                    at: value.location, in: grid, geometry: geometry
                                )
                            else { return }
                            scrubbing.move(cell)
                        }
                        .onEnded { _ in scrubbing.end() }
                        .updating($scrubTouch) { _, touching, _ in touching = true }
                )
                // `@GestureState` resets on EVERY way the gesture stops, cancellation included —
                // the one signal SwiftUI gives for a drag the system takes away. On a normal end
                // it fires after `end()`, where the roll-back is a no-op.
                .onChange(of: scrubTouch) { _, touching in
                    if !touching { scrubbing.cancelled() }
                }
                // One tick per DAY crossed, not per frame: the trigger is the chosen day, so a
                // finger travelling inside one square is silent and every boundary is felt. The
                // feel itself comes from the act table, where it can be asserted.
                .sensoryFeedback(trigger: scrubbing.selectedKey) { _, _ in
                    MemoAct.dayScrubbed.feedback
                }
                // ONE element with a value, not eighty-four with labels. A rotor that stops on
                // every square is one nobody can get past, and a square is a day rather than a
                // control — the grid IS the target, and a swipe steps the day the way it steps a
                // picker (HIG, Charting data).
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Activity")
                .accessibilityValue(
                    HeatmapScrub.spoken(scrubbing.selectedKey, in: grid) ?? summary ?? grid.summary
                )
                // Activating the grid settles the DATE FIELD; the sheet stays over it (MEMNG-178),
                // so the hint points at the row that ends the exercise rather than promising an
                // opening this element does not perform (MEMNG-187).
                .accessibilityHint(
                    "Adjust to choose a day. Activating sets the date; the Show button below "
                        + "opens that day."
                )
                .accessibilityAdjustableAction { direction in
                    let step: Int
                    switch direction {
                    case .increment: step = 1
                    case .decrement: step = -1
                    // A direction this SDK has not shipped yet must not silently mean "later".
                    @unknown default: return
                    }
                    guard
                        let cell = HeatmapScrub.stepped(
                            from: scrubbing.selectedKey, by: step, in: grid
                        )
                    else { return }
                    scrubbing.move(cell)
                }
                // Activation is the release a swipe never performs. It re-chooses the day the
                // value already names, so settling on the day shown takes one action rather than
                // an adjustment there and back.
                .accessibilityAction {
                    guard let cell = HeatmapScrub.cell(for: scrubbing.selectedKey, in: grid)
                    else { return }
                    scrubbing.move(cell)
                    scrubbing.end()
                }
        } else {
            // Inert, the whole grid is one element saying what it amounts to: the web client's
            // cells are non-interactive `<span>`s and this is the parity port of them.
            squares
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(summary ?? grid.summary)
        }
    }

    /// The squares, laid out from the width the card offers rather than from the text size
    /// (MEMNG-186 — `HeatmapGeometry` says why).
    ///
    /// Declared row-major, because that is the order a `Layout` receives its subviews in and the
    /// order `HeatmapSquaresLayout` places them by. EVERY slot is declared, the empty ones a short
    /// trailing column leaves included, so a position in that flat list is a (column, row) with no
    /// exception in it.
    private var squares: some View {
        HeatmapSquaresLayout(
            columns: grid.columns.count,
            rowsPerColumn: HeatmapPresentation.daysPerColumn,
            gap: Self.gap
        ) {
            ForEach(0..<HeatmapPresentation.daysPerColumn, id: \.self) { row in
                ForEach(grid.columns.indices, id: \.self) { column in
                    square(row: row, of: grid.columns[column])
                }
            }
        }
        // What the gesture reads its geometry back from. The layout answers with its own size, so
        // this is the grid's drawn width and not the room it was offered.
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            laidOutWidth = width
        }
    }

    /// A day, or the empty slot a short trailing column leaves behind — drawn as nothing at all
    /// rather than as a zero-count day, which would claim a day that has not happened yet.
    @ViewBuilder
    private func square(row: Int, of column: [HeatCell]) -> some View {
        if column.indices.contains(row) {
            swatch(column[row])
        } else {
            Color.clear
        }
    }

    private func swatch(_ cell: HeatCell) -> some View {
        // The chosen day outranks today's own outline: on the day they are the same square, the
        // ring that says "this is what the field is on" is the one worth drawing.
        let selected = scrubbing?.selectedKey == cell.date
        return RoundedRectangle(cornerRadius: DesignTokens.Space.hair, style: .continuous)
            .fill(Self.fill(for: cell.level))
            .overlay {
                if selected || cell.isToday {
                    RoundedRectangle(cornerRadius: DesignTokens.Space.hair, style: .continuous)
                        .strokeBorder(.primary, lineWidth: selected ? 2 : 1)
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
