import AVFoundation
import Foundation
import ImageIO

/// Reading one file's capture date out of the file itself.
///
/// It lives HERE, in the layer that owns a queued capture, because it is the one layer both places
/// that need it can reach: the composer above and the share extension beside it. An extension may
/// carry no client, no session and no credential, and this carries none of those — it is file
/// metadata and arithmetic, and what it decides (the memo's date, the attachments' order) is what
/// the manifest beside it records.
///
/// Everything about the read is deliberately narrow. It is METADATA ONLY: an image is opened lazily
/// and only its EXIF dictionary is looked at, and a movie's metadata is loaded without its samples
/// ever being read. It touches exactly the tags the rules name — `DateTimeOriginal`,
/// `OffsetTimeOriginal`, `OffsetTime`, `com.apple.quicktime.creationdate`, the movie header — so no
/// GPS tag is read, and nothing that is read is ever logged. And it never throws: a file that says
/// nothing, a corrupt file and a file this process could not open all read as `.empty`, because a
/// capture date the app cannot prove is worth less than none.
///
/// `nonisolated` and `async` together are what keep it off the main actor: a nonisolated async
/// function does not inherit its caller's actor, so a composer on the main actor that awaits this
/// is not the thread that decodes anything.
public enum CaptureReader {
    /// How long one file may take before it is treated as having said nothing. The server's own
    /// extraction deadline is five seconds; a read that has not finished by then is not coming.
    public static let deadline: Duration = .seconds(5)

    public static func read(fileAt url: URL, mime: String, now: Date = Date()) async
        -> CaptureReading
    {
        await withDeadline {
            if mime.hasPrefix("video/") {
                return await videoReading(at: url, now: now)
            }
            return imageReading(at: url)
        }
    }

    /// The PRIMARY image's two date tags.
    ///
    /// The primary index rather than 0: a HEIC out of an iPhone is a container of several images,
    /// and the one the person sees is not always the first item in it. Reading item 0 would date a
    /// memo by a thumbnail or an auxiliary picture — and the vendored `heic-offset.heic` fixture is
    /// exactly that shape, so the mistake fails a test rather than shipping.
    static func imageReading(at url: URL) -> CaptureReading {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return .empty }
        let index = CGImageSourceGetPrimaryImageIndex(source)
        guard
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil)
                as? [CFString: Any],
            let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        else { return .empty }
        let dateTime = exif[kCGImagePropertyExifDateTimeOriginal] as? String
        let offset =
            exif[kCGImagePropertyExifOffsetTimeOriginal] as? String
            ?? exif[kCGImagePropertyExifOffsetTime] as? String
        return CaptureTags.imageReading(dateTimeOriginal: dateTime, offset: offset)
    }

    /// A movie's creation date: the QuickTime key first, the movie header second.
    ///
    /// The two are different facts and the order between them is the rule. `creationdate` is what a
    /// camera wrote with the offset it was standing in, so it is an exact instant. The header is a
    /// bare UTC count from 1904 that half the world's muxers leave at zero, so it is taken only
    /// when there is no key, and only inside the range a real recording can fall in.
    ///
    /// AVFoundation surfaces both, distinctly — measured on the vendored fixtures (2026-09-06):
    /// `mov-creationdate.mov` answers the key and nothing else, `mp4-header-only.mp4` answers no
    /// key and a `creationDate` of 2026-02-03T09:30:00Z, which is precisely its `mvhd` field, and
    /// `mp4-zero-header.mp4` answers neither. So no atom parser is written here; the framework's
    /// own answer is the reading, and the rules above are applied to it.
    static func videoReading(at url: URL, now: Date) async -> CaptureReading {
        let asset = AVURLAsset(url: url)
        // Every load below is spelled with do/catch rather than `try?`: these calls return
        // optionals themselves, and `try?` over an optional-returning call is the one place a
        // double optional reads as a single one.
        let metadata: [AVMetadataItem]
        do { metadata = try await asset.load(.metadata) } catch { return .empty }
        let keyed = AVMetadataItem.metadataItems(
            from: metadata, filteredByIdentifier: .quickTimeMetadataCreationDate)
        for item in keyed {
            var text: String?
            do { text = try await item.load(.stringValue) } catch { continue }
            guard let text, let instant = CaptureTags.quickTimeCreationDate(text) else { continue }
            return CaptureReading(instant: instant, civil: nil, source: .quicktime)
        }
        var header: Date?
        do {
            if let creation = try await asset.load(.creationDate) {
                header = try await creation.load(.dateValue)
            }
        } catch { return .empty }
        guard let header, let accepted = CaptureTags.acceptedHeaderInstant(header, now: now) else {
            return .empty
        }
        return CaptureReading(instant: accepted, civil: nil, source: .quicktime)
    }

    /// The read, or nothing at all if it takes longer than a read of a file's header ever should.
    ///
    /// A bound rather than a hope: the composer will not let a memo be posted until every item has
    /// SETTLED, so a read that hangs would hang the Post button with it. Settling as "no date" is
    /// the answer that keeps the sheet usable, and it is the same answer the SPA reaches when its
    /// own poll runs out.
    static func withDeadline(
        _ duration: Duration = CaptureReader.deadline,
        _ work: @escaping @Sendable () async -> CaptureReading
    ) async -> CaptureReading {
        await withTaskGroup(of: CaptureReading?.self, returning: CaptureReading.self) { group in
            group.addTask { await work() }
            group.addTask {
                try? await Task.sleep(for: duration)
                return Task.isCancelled ? nil : CaptureReading.empty
            }
            var answer: CaptureReading?
            if let first = await group.next() { answer = first }
            group.cancelAll()
            return answer ?? .empty
        }
    }
}
