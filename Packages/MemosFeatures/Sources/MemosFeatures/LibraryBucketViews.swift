import MemosCore
import SwiftUI

/// The Library's Years view (MEMNG-586): one card per year, its cover, its count and its name.
///
/// Everything it draws arrives as a value — the buckets, what the store last failed with and what
/// a tap means — so a test can host it without a session, the way `LibraryGrid` is hosted.
struct LibraryYearsGrid: View {
    /// Newest first, as the server listed them.
    let years: [LibraryBucket]
    let errorText: String?
    /// A year was tapped: the screen shows that year's days.
    let chooseYear: (String) -> Void

    var body: some View {
        ScrollView {
            if let error = errorText {
                NoticeCard(text: error, tone: .error)
                    .padding(.horizontal, DesignTokens.Space.roomy)
            }
            LazyVGrid(
                columns: [
                    GridItem(.adaptive(minimum: 150), spacing: DesignTokens.Space.regular)
                ],
                spacing: DesignTokens.Space.roomy
            ) {
                ForEach(years) { year in
                    LibraryYearCard(bucket: year)
                        .contentShape(.rect)
                        .onTapGesture { chooseYear(year.key) }
                }
            }
            .padding(DesignTokens.Space.roomy)
        }
    }
}

/// One year: its cover, then its name and how many files fall in it.
struct LibraryYearCard: View {
    let bucket: LibraryBucket

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.hair) {
            LibraryBucketCover(bucket: bucket)
                .clipShape(.rect(cornerRadius: DesignTokens.Radius.tile))
                .padding(.bottom, DesignTokens.Space.tight)
            Text(bucket.key)
                .font(.headline)
            Text(bucketCountLabel(bucket.count))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

/// The Library's Months view (plan decision 9): each month's bold title over a mosaic of the days
/// it shows, edge to edge with hairline gaps, and an "and N more days" line under a month that has
/// more. Which days, in which frames, is decided by `mosaicMonths`; this draws it.
struct LibraryMonthsMosaic: View {
    let months: [LibraryMosaicMonth]
    /// The year a Years card narrowed the days to, or nil for every year.
    let year: String?
    let errorText: String?
    /// Widens the days back to every year.
    let clearYear: () -> Void
    /// A day was tapped, or a month's "more days" line: the screen jumps to the All grid at that
    /// day (MEMNG-587).
    let showDay: (LibraryBucket) -> Void
    /// The `YYYY-MM` month the All view's date pill asked for, scrolled to once the months are
    /// read (plan page 3929 decision 13); nil when nothing asked.
    var target: String?
    /// Told once the target is scrolled to, or once the months are read without it.
    var reachedTarget: () -> Void = {}
    /// Told before the scroll to the target, so the move it makes counts as a scroll (MEMNG-679).
    @Environment(AppDock.self) private var dock: AppDock?

    var body: some View {
        ScrollViewReader { proxy in
            scroll
                .onChange(
                    of: MonthTargetReadiness(target: target, months: months.map(\.key)),
                    initial: true
                ) {
                    bring(proxy)
                }
        }
    }

    /// A month Months does not show is not waited for: the view opens at its top, as the web's does.
    private func bring(_ proxy: ScrollViewProxy) {
        guard let target, !months.isEmpty else { return }
        if months.contains(where: { $0.key == target }) {
            dock?.askedToJump()
            proxy.scrollTo(target, anchor: .top)
        }
        reachedTarget()
    }

    private var scroll: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: DesignTokens.Space.section) {
                if let error = errorText {
                    NoticeCard(text: error, tone: .error)
                        .padding(.horizontal, DesignTokens.Space.roomy)
                }
                if let year {
                    HStack {
                        Text(year).font(.title3.bold())
                        Spacer(minLength: 0)
                        Button("All Years", action: clearYear)
                    }
                    .padding(.horizontal, DesignTokens.Space.roomy)
                }
                ForEach(months) { month in
                    LibraryMosaicMonthSection(month: month, showDay: showDay)
                        .id(month.key)
                }
            }
            .padding(.vertical, DesignTokens.Space.tight)
        }
    }
}

/// What Months asks again on for the pill's month: the month, and the months it has to look in.
private struct MonthTargetReadiness: Equatable {
    let target: String?
    let months: [String]
}

/// One month of the mosaic: its title, its tiles in the frames their slots name, and the line
/// that opens All at the month's first SHOWN day when days were left out.
struct LibraryMosaicMonthSection: View {
    let month: LibraryMosaicMonth
    let showDay: (LibraryBucket) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.snug) {
            Text(month.label)
                .font(.title3.bold())
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, DesignTokens.Space.roomy)
            MonthMosaicLayout(slots: month.tiles.map(\.slot), gap: DesignTokens.Space.hair) {
                ForEach(month.tiles) { tile in
                    Button {
                        showDay(tile.bucket)
                    } label: {
                        LibraryDayTile(tile: tile)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(tile.dayLabel)
                }
            }
            if let more = month.moreDaysLabel, let first = month.firstShownDay {
                Button(more) { showDay(first) }
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, DesignTokens.Space.roomy)
            }
        }
    }
}

/// One day of the mosaic: its cover in the shape of its frame and the day of the month, top-left.
/// No count: plan decision 9 puts no badge on a day tile.
struct LibraryDayTile: View {
    let tile: LibraryMosaicTile

    var body: some View {
        LibraryBucketCover(
            bucket: tile.bucket,
            aspectRatio: tile.slot == .wide ? 16 / 9 : 1,
            cornerRadius: DesignTokens.Radius.mosaic
        )
        .overlay(alignment: .topLeading) {
            Text(tile.dayLabel)
                .font(.body.bold())
                .foregroundStyle(.white)
                .shadow(radius: 2)
                .padding(.horizontal, DesignTokens.Space.snug)
                .padding(.top, DesignTokens.Space.tight)
        }
        .clipShape(.rect(cornerRadius: DesignTokens.Radius.mosaic))
    }
}

/// A bucket's cover, square unless a mosaic frame asks for another shape: the picture through the
/// same tile and loader the grid uses, or a placeholder when the bucket names no cover that
/// resolves.
///
/// A cover is never assumed. `LibraryBucket.coverThumbnailURL` is nil when the server's URL does
/// not resolve, and a tile handed a nil URL would wear the failure glyph — which says the file is
/// broken, when all that is missing is a picture to put on a day.
struct LibraryBucketCover: View {
    let bucket: LibraryBucket
    /// Width over height; the picture fills it.
    var aspectRatio: Double = 1
    /// The corner the picture is cut to (`AttachmentThumbnail.cornerRadius`).
    var cornerRadius: CGFloat = DesignTokens.Radius.tile

    var body: some View {
        if let cover = Self.attachment(for: bucket) {
            AttachmentThumbnail(
                attachment: cover,
                tier: .thumb,
                slot: AttachmentSlot(aspectRatio: aspectRatio, contentMode: .fill),
                cornerRadius: cornerRadius
            )
        } else {
            Color.clear
                .aspectRatio(aspectRatio, contentMode: .fit)
                .overlay {
                    ZStack {
                        Rectangle().fill(.quaternary)
                        Image(systemName: "photo.on.rectangle")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
                }
        }
    }

    /// The cover as the attachment the grid's tile loads, or nil when there is none to load.
    ///
    /// Keyed by the cover's own uid, so the loader's `(uid, tier)` cache serves a cover the grid
    /// already fetched, and the signed URL the bucket carries is the one fetched. The kind is
    /// written as a picture because the bucket's URL already IS the still: a clip's poster would
    /// otherwise be asked for, and a bucket carries none.
    static func attachment(for bucket: LibraryBucket) -> MemoAttachment? {
        guard let url = bucket.coverThumbnailURL else { return nil }
        return MemoAttachment(
            uid: bucket.coverUID,
            mime: "image/jpeg",
            status: .ready,
            thumbnailURL: url
        )
    }
}
