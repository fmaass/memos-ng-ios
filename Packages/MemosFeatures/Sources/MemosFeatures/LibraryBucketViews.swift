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

/// The Library's Months view: each month's header over a mosaic of its days, a tile per day with
/// that day's cover and count.
struct LibraryMonthsMosaic: View {
    let months: [LibraryMosaicMonth]
    /// The year a Years card narrowed the days to, or nil for every year.
    let year: String?
    let errorText: String?
    /// Widens the days back to every year.
    let clearYear: () -> Void
    /// A day was tapped: the screen jumps to the All grid at that day (MEMNG-587).
    let showDay: (LibraryBucket) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: DesignTokens.Space.tight) {
                if let error = errorText {
                    NoticeCard(text: error, tone: .error)
                }
                if let year {
                    HStack {
                        Text(year).font(.title3.bold())
                        Spacer(minLength: 0)
                        Button("All Years", action: clearYear)
                    }
                }
                ForEach(months) { month in
                    LibraryMonthHeader(label: month.label)
                    LazyVGrid(
                        columns: [
                            GridItem(.adaptive(minimum: 76), spacing: DesignTokens.Space.tight)
                        ],
                        spacing: DesignTokens.Space.tight
                    ) {
                        ForEach(month.tiles) { tile in
                            LibraryDayTile(tile: tile)
                                .contentShape(.rect)
                                .onTapGesture { showDay(tile.bucket) }
                        }
                    }
                }
            }
            .padding(.horizontal, DesignTokens.Space.snug)
            .padding(.vertical, DesignTokens.Space.tight)
        }
    }
}

/// One day of the mosaic: its cover, the day of the month and how many files fall on it.
struct LibraryDayTile: View {
    let tile: LibraryMosaicTile

    var body: some View {
        LibraryBucketCover(bucket: tile.bucket)
            .overlay(alignment: .topLeading) {
                Text(tile.dayLabel)
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .shadow(radius: 2)
                    .padding(DesignTokens.Space.tight)
            }
            .overlay(alignment: .bottomTrailing) {
                Text("\(tile.bucket.count)")
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
                    .shadow(radius: 2)
                    .padding(DesignTokens.Space.tight)
            }
            .clipShape(.rect(cornerRadius: DesignTokens.Radius.tile))
    }
}

/// A bucket's cover, square: the picture through the same tile and loader the grid uses, or a
/// placeholder when the bucket names no cover that resolves.
///
/// A cover is never assumed. `LibraryBucket.coverThumbnailURL` is nil when the server's URL does
/// not resolve, and a tile handed a nil URL would wear the failure glyph — which says the file is
/// broken, when all that is missing is a picture to put on a day.
struct LibraryBucketCover: View {
    let bucket: LibraryBucket

    var body: some View {
        if let cover = Self.attachment(for: bucket) {
            AttachmentThumbnail(attachment: cover, tier: .thumb, slot: MemoPresentation.gridSlot)
        } else {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
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
