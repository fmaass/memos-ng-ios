import Foundation
import MemosCore
import Testing

@Suite("SSEParser")
struct SSEParserTests {
    private func parse(_ text: String) -> [ServerSentEvent] {
        var parser = SSEParser()
        return parser.consume(Array(text.utf8))
    }

    /// The same bytes, cut in two at every position there is — the boundary a network chunk falls
    /// on is not the parser's to choose, so every one of them has to produce the same events.
    private func parseAtEverySplit(_ text: String) -> [[ServerSentEvent]] {
        let bytes = Array(text.utf8)
        return (0...bytes.count).map { cut in
            var parser = SSEParser()
            var events = parser.consume(bytes[0..<cut])
            events += parser.consume(bytes[cut...])
            return events
        }
    }

    @Test("the frames this server writes come back as one event each")
    func liveFrames() {
        let events = parse(SSEFixture.liveStream)
        #expect(events.count == 5)
        #expect(events.allSatisfy { $0.type == "message" })
        #expect(events.allSatisfy { $0.lastEventID == nil })
        #expect(
            events.first?.data == #"{"uid": "a1b2c3d4", "status": "pending", "progress_pct": 0}"#
        )
    }

    @Test("data lines are joined with newlines and the trailing one is dropped")
    func multiLineData() {
        let events = parse("data: first\ndata: second\ndata: third\n\n")
        #expect(events.count == 1)
        #expect(events.first?.data == "first\nsecond\nthird")
    }

    @Test("a data field with an empty value still contributes a line")
    func emptyDataLines() {
        // `data` with no colon at all, and `data:` with nothing after it, are both an empty value.
        #expect(parse("data\n\n").first?.data == "")
        #expect(parse("data:\n\n").first?.data == "")
        #expect(parse("data: a\ndata\ndata: b\n\n").first?.data == "a\n\nb")
    }

    @Test("exactly one leading space is framing, the rest is value")
    func leadingSpace() {
        #expect(parse("data:  padded\n\n").first?.data == " padded")
        #expect(parse("data:tight\n\n").first?.data == "tight")
    }

    @Test("comments carry nothing and never dispatch an event")
    func comments() {
        #expect(parse(": keep-alive\n\n").isEmpty)
        let events = parse(": keep-alive\ndata: real\n: another\n\n")
        #expect(events.count == 1)
        #expect(events.first?.data == "real")
    }

    @Test("an event type applies to its own event and is reset by the next")
    func eventTypes() {
        let events = parse("event: ping\ndata: 1\n\ndata: 2\n\n")
        #expect(events.map(\.type) == ["ping", "message"])
    }

    @Test("retry is read in milliseconds, and only when it is digits")
    func retryField() {
        var parser = SSEParser()
        _ = parser.consume(Array("retry: 4500\n\n".utf8))
        #expect(parser.reconnectionTime == 4.5)
        _ = parser.consume(Array("retry: soon\n\n".utf8))
        #expect(parser.reconnectionTime == 4.5, "a non-numeric retry leaves the last one standing")
        _ = parser.consume(Array("retry: 0\n\n".utf8))
        #expect(parser.reconnectionTime == 0)
    }

    @Test("an id sticks to every later event until the stream changes it")
    func idField() {
        var parser = SSEParser()
        let first = parser.consume(Array("id: 42\ndata: one\n\ndata: two\n\n".utf8))
        #expect(first.map(\.lastEventID) == ["42", "42"])
        #expect(parser.lastEventID == "42")
        let second = parser.consume(Array("id: 43\ndata: three\n\n".utf8))
        #expect(second.first?.lastEventID == "43")
    }

    @Test("an id on its own becomes the stream's without dispatching an event")
    func idWithoutData() {
        var parser = SSEParser()
        #expect(parser.consume(Array("id: 7\n\n".utf8)).isEmpty)
        #expect(parser.lastEventID == "7")
    }

    @Test("an id containing a NUL is ignored, not stored")
    func idWithNul() {
        var parser = SSEParser()
        _ = parser.consume(Array("id: 9\n\n".utf8))
        _ = parser.consume(Array("id: bad\u{0000}id\ndata: x\n\n".utf8))
        #expect(parser.lastEventID == "9")
    }

    @Test("a parser resumes from the id the last connection reached")
    func seededID() {
        var parser = SSEParser(lastEventID: "88")
        #expect(parser.lastEventID == "88")
        #expect(parser.consume(Array("data: x\n\n".utf8)).first?.lastEventID == "88")
    }

    @Test("CR, LF and CRLF all end a line")
    func lineTerminators() {
        // Each CR-terminated stream ends with a comment line so that the blank line dispatching
        // the event is not the last thing in it — see the held trailing CR below.
        #expect(parse("data: a\rdata: b\r\r: end\r").first?.data == "a\nb")
        #expect(parse("data: a\r\ndata: b\r\n\r\n").first?.data == "a\nb")
        #expect(parse("data: a\ndata: b\n\n").first?.data == "a\nb")
    }

    @Test("a CR at the end of what has arrived is held until the next byte says what it was")
    func trailingCarriageReturnIsHeld() {
        var parser = SSEParser()
        #expect(parser.consume(Array("data: a\r\r".utf8)).isEmpty)
        #expect(parser.consume(Array("\n".utf8)).first?.data == "a")
    }

    @Test("a CRLF split across two chunks is one terminator, not two")
    func crlfAcrossChunks() {
        var parser = SSEParser()
        var events = parser.consume(Array("data: x\r".utf8))
        events += parser.consume(Array("\ndata: y\r\n\r\n".utf8))
        // Held wrongly, the lone CR ends the line AND the following LF dispatches an empty one,
        // splitting one event into two.
        #expect(events.count == 1)
        #expect(events.first?.data == "x\ny")
    }

    @Test("a leading BOM is not part of the first field name")
    func byteOrderMark() {
        #expect(parse("\u{FEFF}data: x\n\n").first?.data == "x")
        var parser = SSEParser()
        // The three BOM bytes, arriving one at a time.
        for byte in Array("\u{FEFF}".utf8) {
            #expect(parser.consume([byte]).isEmpty)
        }
        #expect(parser.consume(Array("data: x\n\n".utf8)).first?.data == "x")
    }

    @Test("every chunk boundary in the live stream produces the same events")
    func everySplitOfTheLiveStream() {
        let whole = parse(SSEFixture.liveStream)
        for events in parseAtEverySplit(SSEFixture.liveStream) {
            #expect(events == whole)
        }
    }

    @Test("every chunk boundary in a stream using every field produces the same events")
    func everySplitOfATortureStream() {
        let stream =
            ": opening comment\r\n"
            + "retry: 2500\r\n"
            + "id: 17\r\n"
            + "event: media\r\n"
            + #"data: {"a": 1}"# + "\r\n"
            + #"data: {"b": 2}"# + "\r\n"
            + "\r\n"
            + "data: plain\n"
            + "\n"
        var parser = SSEParser()
        let whole = parser.consume(Array(stream.utf8))
        #expect(whole.count == 2)
        #expect(parser.reconnectionTime == 2.5)
        #expect(parser.lastEventID == "17")
        #expect(whole.first?.type == "media")
        #expect(whole.first?.data == #"{"a": 1}"# + "\n" + #"{"b": 2}"#)
        #expect(whole.map(\.lastEventID) == ["17", "17"])
        #expect(whole.last?.type == "message")
        #expect(whole.last?.data == "plain")
        for events in parseAtEverySplit(stream) {
            #expect(events == whole)
        }
    }

    @Test("one byte at a time is the same stream as one chunk")
    func bytewise() {
        var parser = SSEParser()
        var events: [ServerSentEvent] = []
        for byte in Array(SSEFixture.liveStream.utf8) {
            events += parser.consume([byte])
        }
        #expect(events == parse(SSEFixture.liveStream))
    }

    @Test("an event with no blank line after it is not dispatched until one arrives")
    func incompleteEventIsHeld() {
        var parser = SSEParser()
        #expect(parser.consume(Array("data: pending\n".utf8)).isEmpty)
        #expect(parser.consume(Array("\n".utf8)).first?.data == "pending")
    }

    @Test("an unknown field is ignored rather than treated as data")
    func unknownField() {
        let events = parse("nonsense: 1\ndata: real\n\n")
        #expect(events.count == 1)
        #expect(events.first?.data == "real")
    }
}
