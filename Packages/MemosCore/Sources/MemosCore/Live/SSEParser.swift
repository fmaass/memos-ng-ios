import Foundation

/// One dispatched Server-Sent Event: what the stream called it, what it carried, and the id that
/// was in force when it was dispatched.
public struct ServerSentEvent: Sendable, Equatable {
    /// The type an event has when the stream named none. It is the spec's default, and it is the
    /// only type this server produces: `sse_event` in memos-ng `app/routers/assets.py:721-722`
    /// writes `data: {json}\n\n` and nothing else — no `event:`, no `id:`, no `retry:`.
    public static let defaultType = "message"

    public let type: String
    /// The `data:` lines joined with newlines, with the trailing newline the spec strips removed.
    public let data: String
    /// The last id the stream declared at or before this event, or nil while it has declared none.
    public let lastEventID: String?

    public init(type: String, data: String, lastEventID: String?) {
        self.type = type
        self.data = data
        self.lastEventID = lastEventID
    }
}

/// The event-stream format, parsed incrementally out of whatever the transport hands over.
///
/// It is written against the SPEC rather than against this server, for one reason and one
/// non-reason. The reason: a parser is fed bytes, not events, and the boundary between two chunks
/// falls wherever the network puts it — mid-line, between a CR and its LF, inside the BOM. Those
/// are the cases that break a line-splitting shortcut, and they are the cases the tests feed it.
/// The non-reason: this server emits none of `event:`, `id:`, `retry:` or comments today
/// (`app/routers/assets.py:721-722`, as of memos-ng a1d493c). They are parsed anyway because the
/// client above honours them the moment the server starts sending them, and a parser that
/// silently ignored a `retry:` would make that a silent behaviour change rather than a working
/// one.
///
/// A `struct` with `mutating` methods, so one connection's parse state cannot leak into another's:
/// a reconnect makes a new parser, seeded with the id the last one reached.
public struct SSEParser: Sendable {
    /// The id the stream has reached — what a reconnect sends back as `Last-Event-ID`.
    public private(set) var lastEventID: String?
    /// The reconnection time the stream last asked for, in seconds. Set the moment a `retry:`
    /// field is parsed, not at dispatch: the spec makes it take effect immediately, and a stream
    /// that says `retry:` and then dies has still said it.
    public private(set) var reconnectionTime: TimeInterval?

    private var buffer: [UInt8] = []
    private var dataBuffer = ""
    private var eventType = ""
    private var lastEventIDBuffer: String?
    private var startedStream = false

    public init(lastEventID: String? = nil) {
        self.lastEventID = lastEventID
        self.lastEventIDBuffer = lastEventID
    }

    /// Feeds bytes in and returns whatever they completed. An incomplete line is kept for the next
    /// call, so the caller never has to care where a chunk ended.
    public mutating func consume(_ bytes: some Sequence<UInt8>) -> [ServerSentEvent] {
        buffer.append(contentsOf: bytes)
        guard stripLeadingBOM() else { return [] }
        var events: [ServerSentEvent] = []
        var start = 0
        while start < buffer.count {
            guard let line = nextLine(from: start) else { break }
            let text = String(decoding: buffer[start..<line.end], as: UTF8.self)
            start = line.next
            if let event = process(line: text) { events.append(event) }
        }
        if start > 0 { buffer.removeFirst(start) }
        return events
    }

    /// The stream's first bytes may be a UTF-8 BOM, which is not part of the first line. Returns
    /// false while what has arrived is still a possible PREFIX of one — three bytes can be split
    /// across three chunks, and consuming `0xEF` as a line would corrupt the first field name.
    private mutating func stripLeadingBOM() -> Bool {
        guard !startedStream else { return true }
        let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
        if buffer.count < bom.count {
            guard !buffer.elementsEqual(bom[0..<buffer.count]) else { return false }
            startedStream = true
            return true
        }
        startedStream = true
        if buffer.starts(with: bom) { buffer.removeFirst(bom.count) }
        return true
    }

    /// The next complete line: where it ends, and where the one after it starts.
    private func nextLine(from start: Int) -> (end: Int, next: Int)? {
        var index = start
        while index < buffer.count {
            let byte = buffer[index]
            if byte == 0x0A { return (index, index + 1) }
            if byte == 0x0D {
                // A CR at the very end of what has arrived may be the first half of a CRLF. Hold
                // it: treating it as a terminator now and finding an LF next would dispatch a
                // phantom empty line, ending an event in the middle of its data.
                guard index + 1 < buffer.count else { return nil }
                return (index, buffer[index + 1] == 0x0A ? index + 2 : index + 1)
            }
            index += 1
        }
        return nil
    }

    private mutating func process(line: String) -> ServerSentEvent? {
        if line.isEmpty { return dispatch() }
        // A line that starts with a colon is a comment. Servers send them to keep an idle
        // connection from being reaped; they carry nothing.
        if line.hasPrefix(":") { return nil }

        let field: String
        var value: String
        if let colon = line.firstIndex(of: ":") {
            field = String(line[line.startIndex..<colon])
            value = String(line[line.index(after: colon)...])
            // Exactly one leading space belongs to the framing, not to the value.
            if value.hasPrefix(" ") { value.removeFirst() }
        } else {
            field = line
            value = ""
        }

        switch field {
        case "event":
            eventType = value
        case "data":
            dataBuffer += value + "\n"
        case "id":
            // A NUL in an id is the one value the spec says to ignore rather than store.
            if !value.contains("\0") { lastEventIDBuffer = value }
        case "retry":
            if !value.isEmpty, value.allSatisfy({ $0.isASCII && $0.isNumber }),
                let milliseconds = Double(value)
            {
                reconnectionTime = milliseconds / 1000
            }
        default:
            break
        }
        return nil
    }

    /// A blank line ends an event. The id becomes the stream's even when there is nothing to
    /// dispatch, which is what makes `id:` on its own a valid resumption marker.
    private mutating func dispatch() -> ServerSentEvent? {
        lastEventID = lastEventIDBuffer
        guard !dataBuffer.isEmpty else {
            eventType = ""
            return nil
        }
        var data = dataBuffer
        if data.hasSuffix("\n") { data.removeLast() }
        let event = ServerSentEvent(
            type: eventType.isEmpty ? ServerSentEvent.defaultType : eventType,
            data: data,
            lastEventID: lastEventID
        )
        dataBuffer = ""
        eventType = ""
        return event
    }
}
