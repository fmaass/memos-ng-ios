import Foundation
import MemosCore
import Testing

@Suite("MediaEvent")
struct MediaEventTests {
    private func frame(_ json: String, type: String = "message") -> ServerSentEvent {
        ServerSentEvent(type: type, data: json, lastEventID: nil)
    }

    @Test("the server's own frames decode to the events it meant")
    func decodesTheLiveStream() throws {
        var parser = SSEParser()
        let frames = parser.consume(Array(SSEFixture.liveStream.utf8))
        let events = try frames.map { try MediaEvent.decode($0) }
        #expect(events == SSEFixture.liveEvents)
    }

    @Test("the ready event carries the layout the worker wrote")
    func readyCarriesMetadata() throws {
        let event = try MediaEvent.decode(
            frame(
                #"{"uid": "a1b2c3d4", "status": "ready", "progress_pct": 100, "width": 4032, "#
                    + #""height": 3024, "blurhash": "LEHV6nWB"}"#
            )
        )
        #expect(event.status == .ready)
        #expect(event.blurhash == "LEHV6nWB")
        let dimensions = try #require(event.dimensions)
        #expect(dimensions.width == 4032)
        #expect(dimensions.height == 3024)
    }

    @Test("a ready event whose metadata is still null has no dimensions and no blurhash")
    func readyWithoutMetadata() throws {
        let event = try MediaEvent.decode(
            frame(
                #"{"uid": "e5f6a7b8", "status": "ready", "progress_pct": 100, "width": null, "#
                    + #""height": null, "blurhash": null}"#
            )
        )
        #expect(event.width == nil)
        #expect(event.height == nil)
        #expect(event.blurhash == nil)
        #expect(event.dimensions == nil)
    }

    @Test("one dimension without the other describes no aspect ratio, so it is not offered")
    func dimensionsAreAPair() throws {
        let event = try MediaEvent.decode(
            frame(#"{"uid": "x", "status": "ready", "width": 4032, "height": null}"#)
        )
        #expect(event.width == 4032)
        #expect(event.dimensions == nil)
    }

    @Test("an absent percentage is absent, not zero")
    func absentProgress() throws {
        let event = try MediaEvent.decode(frame(#"{"uid": "x", "status": "processing"}"#))
        #expect(event.progressPercent == nil)
    }

    @Test("a percentage that arrives as a fraction is rounded rather than losing the event")
    func fractionalProgress() throws {
        let event = try MediaEvent.decode(
            frame(#"{"uid": "x", "status": "processing", "progress_pct": 37.6}"#)
        )
        #expect(event.progressPercent == 38)
        #expect(event.status == .processing)
    }

    @Test("a status this client does not know is a skip, not a failure of the stream")
    func unknownStatus() {
        #expect(throws: MediaEventDecodingError.unknownStatus("quarantined")) {
            try MediaEvent.decode(
                frame(#"{"uid": "x", "status": "quarantined", "progress_pct": 5}"#)
            )
        }
    }

    @Test("a payload that is not this channel's object is a skip")
    func malformedPayload() {
        let error = #expect(throws: MediaEventDecodingError.self) {
            try MediaEvent.decode(frame("not json at all"))
        }
        guard case .some(.malformed) = error else {
            Issue.record("expected a malformed payload, got \(String(describing: error))")
            return
        }
    }

    @Test("a frame missing the uid is a skip, not a half-built event")
    func missingUID() {
        #expect(throws: MediaEventDecodingError.self) {
            try MediaEvent.decode(frame(#"{"status": "ready"}"#))
        }
    }

    @Test("an event type this client does not consume is skipped by name")
    func unsupportedEventType() {
        #expect(throws: MediaEventDecodingError.unsupportedEventType("keepalive")) {
            try MediaEvent.decode(
                frame(#"{"uid": "x", "status": "ready"}"#, type: "keepalive")
            )
        }
    }

    @Test("the statuses are the server's five, spelled as it spells them")
    func statusVocabulary() {
        // memos-ng `app/models.py:31-36`. A rename on either side has to break something.
        #expect(
            MediaAttachmentStatus.allCases.map(\.rawValue)
                == ["uploading", "pending", "processing", "ready", "failed"]
        )
    }

    @Test("only the states the backend never leaves on its own are terminal")
    func terminalStatuses() {
        #expect(MediaAttachmentStatus.uploading.isTerminal == false)
        #expect(MediaAttachmentStatus.pending.isTerminal == false)
        #expect(MediaAttachmentStatus.processing.isTerminal == false)
        #expect(MediaAttachmentStatus.ready.isTerminal)
        #expect(MediaAttachmentStatus.failed.isTerminal)
    }
}
