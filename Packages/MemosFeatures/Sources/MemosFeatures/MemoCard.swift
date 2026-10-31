import CoreGraphics
import MemosCore
import MemosOutbox
import SwiftUI

/// One memo, as a card.
///
/// The card has TWO targets, not one. It used to be a single one edge to edge, because the
/// alternative then was a horizontal `ScrollView` that ate every tap and left the memo reachable
/// only through a chevron. The photos are laid out rather than scrolled now, and since they have
/// somewhere of their own to go — full screen — a tap on a tile opens the picture while the rest
/// of the card still opens the memo.
///
/// Which of the two a tap is depends on where it landed, and that is decided by `MemoCardTap` from
/// the tiles' measured frames rather than by nesting a button inside a button. Nested buttons make
/// the answer a property of SwiftUI's gesture arbitration, which no test in this repo can state;
/// a point and a list of rectangles is a rule that can be asserted.
struct MemoCard: View {
    let memo: Memo
    /// The namespace the full-screen zoom transition matches in — `nil` in a preview or a fitting
    /// test, where there is no viewer to animate into.
    let mediaZoom: Namespace.ID?
    let openMemo: () -> Void
    /// Where BOTH tile destinations go. A photo opens on its own page and a video opens on its
    /// own page already playing, and which of the two it is, is the viewer's decision from the
    /// page it opened on — not a second route out of this card.
    let openAttachment: (MemoAttachment) -> Void
    /// Publishes the tiles the card has MEASURED, as the router sees them.
    ///
    /// `nil` everywhere in the app — nothing in a running card needs them. It exists because the
    /// routing rule is only worth anything over the frames this view really reports: a test that
    /// computes tile rectangles for itself keeps passing after the reporting is deleted, which is
    /// exactly the hole this closes (`MemoCardTapTests`).
    let reportTiles: (([MemoCardTap.Tile]) -> Void)?
    /// The pictures this memo went without, when it was a pending card that said so
    /// (`PendingMemoPresentation.missingNote(count:)`); nil on every other memo.
    let missingNote: String?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .subheadline) private var avatar = DesignTokens.Metric.avatar
    @ScaledMetric(relativeTo: .body) private var pairHeight = DesignTokens.Metric.photoPair
    @ScaledMetric(relativeTo: .body) private var soloHeight = DesignTokens.Metric.photoSolo
    @ScaledMetric(relativeTo: .body) private var rowHeight = DesignTokens.Metric.photoRow
    /// Where each drawn tile ended up, in the card's own coordinate space. Kept per card rather
    /// than globally so scrolling the timeline does not rewrite it on every frame.
    @State private var tileFrames: [String: CGRect] = [:]

    private static let tapSpace = "memo-card"

    /// Spelled out rather than synthesised so a card can still be built with nothing but a memo —
    /// which is what a fitting test and a preview do.
    init(
        memo: Memo,
        mediaZoom: Namespace.ID? = nil,
        openMemo: @escaping () -> Void = {},
        openAttachment: @escaping (MemoAttachment) -> Void = { _ in },
        reportTiles: (([MemoCardTap.Tile]) -> Void)? = nil,
        missingNote: String? = nil
    ) {
        self.memo = memo
        self.mediaZoom = mediaZoom
        self.openMemo = openMemo
        self.openAttachment = openAttachment
        self.reportTiles = reportTiles
        self.missingNote = missingNote
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.regular) {
            header
            if MemoPresentation.hasRenderableBody(memo.content) {
                MemoMarkdownView(content: memo.content)
                    .padding(.horizontal, DesignTokens.Space.roomy)
            }
            photos
            if !memo.tags.isEmpty {
                tags
            }
            // The pending card's line, drawn the same way, so the swap does not take it away.
            if let missingNote {
                Label(missingNote, systemImage: "photo.badge.exclamationmark")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, DesignTokens.Space.roomy)
            }
        }
        .padding(.vertical, DesignTokens.Space.roomy)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: DesignTokens.Radius.card))
        .contentShape(.rect)
        .gesture(
            SpatialTapGesture(coordinateSpace: .named(Self.tapSpace))
                .onEnded { value in handleTap(at: value.location) }
        )
        // Declared on the wrapper OUTSIDE the gesture and the tiles, so both resolve the same
        // space: a named space is looked up in a view's ancestors.
        .coordinateSpace(.named(Self.tapSpace))
        // Published from the same `tileFrames` the router reads, so an observer cannot see a set
        // of tiles the router does not have.
        .onChange(of: tileFrames) { _, _ in reportTiles?(tiles) }
        // A gesture carries no meaning to VoiceOver, so the card says what it is and what it does.
        // The combined element is what a single card-wide button used to produce.
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, openMemo)
        .accessibilityActions {
            // A gesture-routed card has no targets a screen reader can find, so the two things a
            // tap can do are offered by name. The video one is named for what it DOES — the
            // viewer it opens is already playing — because "open photo" on a video says nothing.
            if let playable = memo.attachments.first(where: { MemoCardTap.plays($0) }) {
                Button("Play video") { openAttachment(playable) }
            }
            let openable = memo.attachments.first {
                MediaViewerPresentation.isViewable($0) && !MemoCardTap.plays($0)
            }
            if let openable {
                Button("Open photo") { openAttachment(openable) }
            }
        }
    }

    /// The drawn tiles, in card order, as the router sees them. A tile that has not reported its
    /// frame yet is simply not a target — the memo is, which is what the whole card did before.
    ///
    /// Every attachment is drawn now (justified rows hide nothing behind a count), so the router
    /// sees every one of them, wherever the solver put it: the frames come from the tiles
    /// themselves, so a change of arrangement needs no change here.
    private var tiles: [MemoCardTap.Tile] {
        memo.attachments.compactMap { attachment in
            tileFrames[attachment.uid].map {
                MemoCardTap.Tile(
                    uid: attachment.uid,
                    frame: $0,
                    plays: MemoCardTap.plays(attachment)
                )
            }
        }
    }

    private func handleTap(at point: CGPoint) {
        switch MemoCardTap.destination(at: point, tiles: tiles) {
        case .memo:
            openMemo()
        case .attachment(let uid):
            guard let attachment = attachment(uid) else {
                openMemo()
                return
            }
            openAttachment(attachment)
        case .playback(let uid):
            // Same door as a photo tile. The two destinations still differ in what they MEAN,
            // and the viewer acts on that difference when it opens; the card's job ends at
            // opening it on the right page.
            guard let attachment = attachment(uid) else {
                openMemo()
                return
            }
            openAttachment(attachment)
        }
    }

    private func attachment(_ uid: String) -> MemoAttachment? {
        memo.attachments.first { $0.uid == uid }
    }

    /// At an accessibility text size a row of avatar, name and pill cannot share a line without
    /// something being cut; it stacks instead. That is the whole reason this is a switch and not
    /// one `HStack`.
    @ViewBuilder
    private var header: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: DesignTokens.Space.snug) {
                HStack(spacing: DesignTokens.Space.snug) {
                    OwnerAvatar(owner: memo.owner, size: avatar)
                    identity
                }
                HStack(spacing: DesignTokens.Space.snug) {
                    pin
                    archived
                    VisibilityPill(visibility: memo.visibility)
                }
            }
            .padding(.horizontal, DesignTokens.Space.roomy)
        } else {
            HStack(spacing: DesignTokens.Space.snug) {
                OwnerAvatar(owner: memo.owner, size: avatar)
                identity
                Spacer(minLength: DesignTokens.Space.snug)
                pin
                archived
                VisibilityPill(visibility: memo.visibility)
            }
            .padding(.horizontal, DesignTokens.Space.roomy)
        }
    }

    /// Said out loud, because a card gives no other sign of it.
    ///
    /// An archived memo only appears at all under a search that asked for the archived ones, and
    /// there it sits among active memos looking exactly like them — so the one fact that explains
    /// why it is not in the timeline is the one fact the card was not saying.
    @ViewBuilder
    private var archived: some View {
        if memo.isArchived {
            ArchivedPill()
        }
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(MemoCardPresentation.displayName(forOwner: memo.owner))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            Text(memo.createdAt, format: .dateTime.hour().minute())
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var pin: some View {
        if memo.pinned {
            Image(systemName: "pin.fill")
                .font(.caption)
                .foregroundStyle(DesignTokens.accent)
                .accessibilityLabel("Pinned")
        }
    }

    @ViewBuilder
    private var photos: some View {
        switch MemoCardPresentation.photoLayout(for: memo.attachments.count) {
        case .none:
            EmptyView()
        case .solo:
            AttachmentThumbnail(
                attachment: memo.attachments[0],
                tier: .mobile,
                slot: MemoPresentation.soloSlot(for: memo.attachments[0])
            )
            // A CAP, not a height: a photo shorter than this stands at its own size, and a tall
            // one narrows to fit rather than being cropped to it.
            .frame(maxHeight: soloHeight)
            .mediaTapTarget(
                memo.attachments[0],
                in: $tileFrames,
                space: Self.tapSpace,
                zoom: mediaZoom
            )
            .padding(.horizontal, DesignTokens.Space.roomy)
        case .pair:
            HStack(spacing: DesignTokens.Space.snug) {
                ForEach(memo.attachments) { attachment in
                    AttachmentThumbnail(attachment: attachment, slot: MemoPresentation.gridSlot)
                        .mediaTapTarget(
                            attachment,
                            in: $tileFrames,
                            space: Self.tapSpace,
                            zoom: mediaZoom
                        )
                }
            }
            .frame(maxHeight: pairHeight)
            .padding(.horizontal, DesignTokens.Space.roomy)
        case .justified:
            // Every photo, each at its own ratio, in rows that fill the card exactly. No "+N", no
            // horizontal scroller: what the memo holds is what the card shows.
            JustifiedRowsLayout(
                ratios: JustifiedGallery.ratios(of: memo.attachments),
                targetHeight: rowHeight,
                gap: DesignTokens.Space.tight
            ) {
                ForEach(memo.attachments) { attachment in
                    AttachmentThumbnail(
                        attachment: attachment,
                        slot: MemoPresentation.justifiedSlot(for: attachment)
                    )
                    .mediaTapTarget(
                        attachment,
                        in: $tileFrames,
                        space: Self.tapSpace,
                        zoom: mediaZoom
                    )
                }
            }
            .padding(.horizontal, DesignTokens.Space.roomy)
        }
    }

    private var tags: some View {
        HStack(spacing: DesignTokens.Space.tight) {
            ForEach(memo.tags, id: \.self) { tag in
                Text("#\(tag)")
                    .font(.caption2)
                    .lineLimit(1)
                    .padding(.horizontal, DesignTokens.Space.snug)
                    .padding(.vertical, DesignTokens.Space.hair)
                    .background(DesignTokens.accent.opacity(0.12), in: .capsule)
                    .foregroundStyle(DesignTokens.accent)
            }
        }
        .padding(.horizontal, DesignTokens.Space.roomy)
    }
}

/// The owner, as a letter in a circle. Decorative: the name is spelled out beside it, so a screen
/// reader that also read the initial would just be stuttering.
struct OwnerAvatar: View {
    let owner: String
    let size: CGFloat

    var body: some View {
        Circle()
            .fill(DesignTokens.accent.opacity(0.16))
            .frame(width: size, height: size)
            .overlay {
                Text(MemoCardPresentation.initial(forOwner: owner))
                    .font(.caption.weight(.bold))
                    .minimumScaleFactor(0.5)
                    .foregroundStyle(DesignTokens.accent)
            }
            .accessibilityHidden(true)
    }
}

/// Who can see this memo, said in one small capsule.
///
/// `fixedSize` is load-bearing rather than decorative: it makes the pill take the width its label
/// actually needs, at any text size, so the label can never be shortened to an ellipsis. Whatever
/// else has to give when the type gets huge, it is not the word that says whether something is
/// private. `DynamicTypeFittingTests` holds that promise to the widest label at the largest size.
struct VisibilityPill: View {
    let visibility: MemoVisibility

    var body: some View {
        Group {
            if let word = visibility.pillLabel {
                Label {
                    Text(word)
                } icon: {
                    Image(systemName: visibility.symbolName)
                }
                .labelStyle(.titleAndIcon)
                .padding(.horizontal, DesignTokens.Space.snug)
                .padding(.vertical, DesignTokens.Space.hair)
                .background(.quaternary, in: .capsule)
            } else {
                // No capsule either: a box drawn around a single glyph is heavier than the glyph,
                // and the point of dropping the word was to stop the common case shouting.
                Image(systemName: visibility.symbolName)
            }
        }
        .font(.caption.weight(.medium))
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .foregroundStyle(.secondary)
        // The word leaves the SCREEN, not the app: a screen reader still hears which it is.
        .accessibilityLabel("Visibility: \(visibility.label)")
    }
}

/// That this memo is in the archive, in the same small capsule the visibility uses.
///
/// It is a WORD and not only a glyph, at every text size: "archived" is not a state anybody can
/// guess from a box icon, and it is the difference between a memo that is missing from the
/// timeline for a reason and one that is missing by accident. `fixedSize` for the same reason the
/// visibility pill has it — the word may never be shortened to an ellipsis.
struct ArchivedPill: View {
    var body: some View {
        Label {
            Text("Archived")
        } icon: {
            Image(systemName: "archivebox")
        }
        .labelStyle(.titleAndIcon)
        .font(.caption.weight(.medium))
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, DesignTokens.Space.snug)
        .padding(.vertical, DesignTokens.Space.hair)
        .background(.quaternary, in: .capsule)
        .foregroundStyle(.secondary)
        .accessibilityLabel("Archived")
    }
}

/// The pending section, and the one place on the timeline whose sentence changes because time
/// passed rather than because something happened. It wakes ONCE, at the earliest instant a row
/// would start saying something else, and re-arms from what that redraw finds — never on a
/// repeating tick, which would redraw a still screen every second for the one second in ninety
/// that has anything to say.
struct PendingSection: View {
    let jobs: [UploadJob]
    let lastProgressAt: [UUID: Date]
    let verdict: UploadVerdict
    let retry: (UUID) -> Void
    let remove: (UUID) -> Void
    /// Cancel on a capture still moving, and Reopen on one already stopped: both ask the queue
    /// for the draft and open the editor on what comes back.
    let restore: (UUID) -> Void
    /// The pending memo cards these rows are, when the `compose.pending-card` switch is on: each
    /// row then carries its capture's date, tags and tiles and the memo card's actions
    /// (MEMNG-951). Nil draws the rows as they were.
    var cards: [PendingMemo]? = nil
    var ledger: TransferLedger? = nil
    /// "Remove" on a pending card: out of the queue while nothing may have reached the server.
    var withdraw: (UUID) -> Void = { _ in }
    /// A visibility chosen on a pending card, for its capture's manifest (MEMNG-971).
    var setVisibility: (UUID, VisibilityChange) -> Void = { _, _ in }

    /// The instant the last arming was measured from. Read here so that writing it re-runs this
    /// body.
    @State private var armedAt = Date()

    var body: some View {
        let now = Date()
        let deadline = PendingMemoPresentation.stallDeadline(
            for: jobs, lastProgressAt: lastProgressAt, after: armedAt)
        Section {
            ForEach(
                PendingMemoPresentation.rows(
                    for: jobs, now: now, lastProgressAt: lastProgressAt, verdict: verdict)
            ) { row in
                let memo = cards?.first { $0.job.id == row.id }
                PendingCard(
                    row: row,
                    retry: { retry(row.id) },
                    remove: { remove(row.id) },
                    cancel: { restore(row.id) },
                    reopen: { restore(row.id) },
                    memo: memo,
                    ledger: ledger,
                    edit: { restore(row.id) },
                    withdraw: { withdraw(row.id) },
                    setVisibility: { setVisibility(row.id, $0) }
                )
                .cardRow()
                // The key the memo it becomes is drawn under (`TimelineStore.identityKey`).
                .id(memo?.id ?? row.id.uuidString)
            }
        } header: {
            SectionHeading(title: "Pending")
        }
        .task(id: deadline) {
            guard let deadline else { return }
            let wait = deadline.timeIntervalSince(Date())
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard !Task.isCancelled else { return }
            armedAt = deadline
        }
    }
}

/// A capture that has not reached the server yet, in the same card the finished memos use — a
/// queued memo is a memo, and a row that looks like a system notice makes it read like an error.
struct PendingCard: View {
    let row: PendingRow
    let retry: () -> Void
    let remove: () -> Void
    let cancel: () -> Void
    let reopen: () -> Void
    var memo: PendingMemo? = nil
    var ledger: TransferLedger? = nil
    var edit: () -> Void = {}
    var withdraw: () -> Void = {}
    var setVisibility: (VisibilityChange) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.snug) {
            if let memo {
                PendingMemoHeader(
                    memo: memo, ledger: ledger, edit: edit, withdraw: withdraw,
                    setVisibility: setVisibility)
            }
            HStack(spacing: DesignTokens.Space.tight) {
                Image(
                    systemName: row.needsAttention
                        ? "exclamationmark.circle.fill" : "clock.arrow.up"
                )
                Text(row.status)
                if row.attachmentCount > 0 {
                    Label("\(row.attachmentCount)", systemImage: "paperclip")
                }
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(
                row.needsAttention ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary)
            )
            if !row.snippet.isEmpty {
                Text(row.snippet).font(.body)
            }
            if let missing = row.missingNote {
                Label(missing, systemImage: "photo.badge.exclamationmark")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            if !row.actions.isEmpty {
                HStack(spacing: DesignTokens.Space.tight) {
                    // Drawn in the order the row offers them, which is the order the presentation
                    // decided: what a person is most likely to want comes first, and a view that
                    // sorted them again would be the second place that decision lives.
                    ForEach(row.actions, id: \.self) { action in
                        switch action {
                        case .retry:
                            Button("Try again", action: retry)
                                .font(.footnote)
                                .buttonStyle(.bordered)
                                .tint(DesignTokens.accent)
                        case .reopen:
                            // Its own word, because a row may offer it beside Try again, and two
                            // buttons reading the same would leave the person guessing which sends.
                            Button("Reopen", action: reopen)
                                .font(.footnote)
                                .buttonStyle(.bordered)
                                .tint(DesignTokens.accent)
                        case .remove:
                            // Destructive, and pressed by a person: nothing here ever decides it.
                            Button("Remove", role: .destructive, action: remove)
                                .font(.footnote)
                                .buttonStyle(.bordered)
                        case .cancel:
                            // Offered only while the queue can still take the capture back, and
                            // the press is not the guard: two landing at once are settled where
                            // the job's state is owned.
                            Button("Cancel", action: cancel)
                                .font(.footnote)
                                .buttonStyle(.bordered)
                                .disabled(row.disabledReasons[.cancel] != nil)
                        }
                    }
                }
                // Each action drawn but not pressable says why, under the buttons.
                ForEach(row.actions.filter { row.disabledReasons[$0] != nil }, id: \.self) {
                    Text(row.disabledReasons[$0] ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(DesignTokens.Space.roomy)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: DesignTokens.Radius.card))
        .overlay {
            RoundedRectangle(cornerRadius: DesignTokens.Radius.card)
                .strokeBorder(
                    row.needsAttention
                        ? AnyShapeStyle(.orange.opacity(0.5))
                        : AnyShapeStyle(DesignTokens.accent.opacity(0.25)),
                    style: StrokeStyle(lineWidth: 1, dash: row.needsAttention ? [] : [4, 3])
                )
        }
    }
}

extension View {
    /// A photo tile that reports the frame it occupies and can be zoomed out of.
    ///
    /// The frame is read in the CARD's coordinate space rather than the screen's: a card-local
    /// rectangle is stable while the timeline scrolls, so this writes state when the layout
    /// changes and not once per scrolled frame.
    func mediaTapTarget(
        _ attachment: MemoAttachment,
        in frames: Binding<[String: CGRect]>,
        space: String,
        zoom: Namespace.ID?
    ) -> some View {
        self
            .mediaTransitionSource(id: attachment.uid, in: zoom)
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .named(space))
            } action: { frame in
                frames.wrappedValue[attachment.uid] = frame
            }
    }
}
