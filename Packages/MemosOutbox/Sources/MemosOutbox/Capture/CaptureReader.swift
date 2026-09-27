import AVFoundation
import Foundation
import ImageIO
import os

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
/// nothing reads as `.empty`, because a capture date the app cannot prove is worth less than none.
/// What it does not do is answer `.empty` for a file it did not hear out — a deadline, a
/// cancellation, a decoder that refused the file (an AVFoundation load that threw, an image ImageIO
/// would open no source or no properties for) — since that would state "no date" about a file
/// nobody finished reading; those carry their `failure` instead, and date nothing all the same. An
/// image ImageIO DID open, whose properties simply hold no EXIF, is a file that says nothing.
///
/// `nonisolated` and `async` together are what keep it off the main actor: a nonisolated async
/// function does not inherit its caller's actor, so a composer on the main actor that awaits this
/// is not the thread that decodes anything.
public enum CaptureReader {
    /// How long one file may take before its read settles as `.deadline`. The server's own
    /// extraction deadline is five seconds; a read that has not finished by then is not coming.
    public static let deadline: Duration = .seconds(5)

    public static func read(
        fileAt url: URL,
        mime: String,
        now: Date = Date(),
        deadline: Duration = CaptureReader.deadline
    ) async -> CaptureReading {
        await withDeadline(deadline) {
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
        var refusal: String?
        if let tags = imageIOTags(at: url, refusal: &refusal) {
            let reading = CaptureTags.imageReading(
                dateTimeOriginal: tags.dateTime, offset: tags.offset)
            if reading.source != nil { return reading }
        }
        // ImageIO reports no EXIF at all for a PNG whose `eXIf` chunk sits after the image data,
        // which is a placement the format allows and the server's reader finds. The chunk walk is
        // the second look, and it reads nothing but that chunk (`PNGExif`).
        if let tags = PNGExif.dateTags(inFileAt: url) {
            return CaptureTags.imageReading(dateTimeOriginal: tags.dateTime, offset: tags.offset)
        }
        if let refusal { return CaptureReading(failure: .undecodable, detail: refusal) }
        return .empty
    }

    /// The two date tags as ImageIO reports them for the PRIMARY image, or nil when it reports no
    /// EXIF dictionary at all.
    ///
    /// Nil is two different answers, and `refusal` is what tells them apart: an image whose
    /// properties hold no EXIF is left without one, while no source or no properties at all is
    /// ImageIO declining the file, described with the status it reported at that moment — read
    /// here, from the source that failed, because asking again later is a different decode.
    static func imageIOTags(
        at url: URL, refusal: inout String?
    ) -> (dateTime: String?, offset: String?)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            refusal = "ImageIO created no source"
            return nil
        }
        let index = CGImageSourceGetPrimaryImageIndex(source)
        guard
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil)
                as? [CFString: Any]
        else {
            let status = CGImageSourceGetStatus(source).rawValue
            refusal = "ImageIO status \(status), no properties for image \(index)"
            return nil
        }
        guard let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] else {
            return nil
        }
        return (
            exif[kCGImagePropertyExifDateTimeOriginal] as? String,
            exif[kCGImagePropertyExifOffsetTimeOriginal] as? String
                ?? exif[kCGImagePropertyExifOffsetTime] as? String
        )
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
        do { metadata = try await asset.load(.metadata) } catch { return refused(error) }
        let keyed = AVMetadataItem.metadataItems(
            from: metadata, filteredByIdentifier: .quickTimeMetadataCreationDate)
        // A key that could not be loaded is not a key that was absent: if nothing after it answers,
        // the movie was not heard out, and the header's silence must not stand in for the key's.
        var unheard: CaptureReading?
        for item in keyed {
            var text: String?
            do {
                text = try await item.load(.stringValue)
            } catch {
                unheard = refused(error)
                continue
            }
            guard let text, let instant = CaptureTags.quickTimeCreationDate(text) else { continue }
            return CaptureReading(instant: instant, civil: nil, source: .quicktime)
        }
        var header: Date?
        do {
            if let creation = try await asset.load(.creationDate) {
                header = try await creation.load(.dateValue)
            }
        } catch { return refused(error) }
        guard let header, let accepted = CaptureTags.acceptedHeaderInstant(header, now: now) else {
            return unheard ?? .empty
        }
        return CaptureReading(instant: accepted, civil: nil, source: .quicktime)
    }

    /// What a throwing AVFoundation load means. It throws for a cancelled load too, and a read the
    /// caller abandoned is not a file the decoder refused.
    private static func refused(_ error: any Error) -> CaptureReading {
        if Task.isCancelled { return CaptureReading(failure: .cancelled) }
        let refusal = error as NSError
        return CaptureReading(
            failure: .undecodable, detail: "\(refusal.domain) \(refusal.code)")
    }

    /// The read, or nothing at all if it takes longer than a read of a file's header ever should.
    ///
    /// A bound rather than a hope, and it bounds the CALLER rather than merely asking the work to
    /// stop. The composer will not let a memo be posted until every item has settled, so a read
    /// that hangs would hang the Post button with it — and a task group cannot be the mechanism,
    /// because a group waits for its children at scope exit and ImageIO does not answer
    /// cancellation. So the work runs detached, the answer arrives through a one-shot claim, and
    /// whichever of the read and the timer speaks first is the answer this returns; a work task
    /// still running afterwards is cancelled and abandoned rather than waited for.
    ///
    /// Settling with no date is what keeps the sheet usable, and it is the same answer the SPA
    /// reaches when its own poll runs out — but it settles as `.deadline` or `.cancelled`, never as
    /// `.empty`, because a timer cannot know what the file says.
    static func withDeadline(
        _ duration: Duration = CaptureReader.deadline,
        _ work: @escaping @Sendable () async -> CaptureReading
    ) async -> CaptureReading {
        let answer = FirstAnswer()
        let worker = Task.detached(priority: .utility) {
            let reading = await work()
            answer.deliver(reading)
        }
        let timer = Task {
            // Only a sleep that ran its whole length is a deadline. A timer cancelled early was
            // cancelled because an answer came first or because the caller went away, and the
            // latter has its own delivery below — letting this one speak too would race it and
            // could call a cancellation a timeout.
            do { try await Task.sleep(for: duration) } catch { return }
            answer.deliver(CaptureReading(failure: .deadline))
        }
        // The caller's cancellation has to reach BOTH: the unstructured children, which are not in
        // its task tree, and the continuation this is parked on, which nothing else would ever
        // resume. It claims the answer FIRST, synchronously, and only then cancels the children:
        // a work woken by its cancellation answers at once, and cancelling it before the claim
        // would hand the answer to whichever of the two got there first.
        let reading = await withTaskCancellationHandler {
            await answer.value
        } onCancel: {
            answer.deliver(CaptureReading(failure: .cancelled))
            worker.cancel()
            timer.cancel()
        }
        worker.cancel()
        timer.cancel()
        return reading
    }
}

/// The one answer a bounded read produces, whoever gets there first.
///
/// The claim is taken under a lock, synchronously, at each place that answers — the work, the
/// timer and the caller's cancellation — so the order in which they happen IS the order in which
/// they claim, with no actor hop between an answer being known and it being claimed. The loser's
/// answer is dropped rather than resuming a continuation twice, which is a crash, not a race to be
/// lived with.
private final class FirstAnswer: Sendable {
    private struct State: Sendable {
        var answered: CaptureReading?
        var waiting: CheckedContinuation<CaptureReading, Never>?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var value: CaptureReading {
        get async {
            await withCheckedContinuation { continuation in
                let answered = state.withLock { state -> CaptureReading? in
                    if let answered = state.answered { return answered }
                    state.waiting = continuation
                    return nil
                }
                if let answered { continuation.resume(returning: answered) }
            }
        }
    }

    func deliver(_ reading: CaptureReading) {
        let waiting = state.withLock { state -> CheckedContinuation<CaptureReading, Never>? in
            guard state.answered == nil else { return nil }
            state.answered = reading
            let waiting = state.waiting
            state.waiting = nil
            return waiting
        }
        waiting?.resume(returning: reading)
    }
}
