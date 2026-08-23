import Foundation

/// One item of a Markdown list, with the state the SPA's task-list plugin gives it.
public struct MarkdownListItem: Sendable, Equatable {
    public var isTask: Bool
    public var checked: Bool
    public var children: [MarkdownNode]
    /// Source line of the item's first paragraph — where the checkbox is drawn. For an item whose
    /// marker sits alone on its line, that is the line AFTER the marker.
    public var contentLine: Int
}

/// The block structure of a memo, in document order.
public indirect enum MarkdownNode: Sendable, Equatable {
    case heading(level: Int, source: String, line: Int)
    case paragraph(source: String, line: Int)
    case code(text: String, line: Int)
    case thematicBreak(line: Int)
    case blockquote(children: [MarkdownNode], line: Int)
    case list(ordered: Bool, items: [MarkdownListItem], line: Int)
    /// Rows of inline sources, header row first.
    case table(rows: [[String]], line: Int)
}

/// The block half of the renderer contract — one parse that everything else reads.
///
/// Which source lines become checkboxes, what a memo projects to for the parity fixture, and
/// which links stay tappable are all answered from THIS tree. A second, regex-shaped opinion
/// about where a task line is would disagree with the renderer the moment a fence, a blockquote
/// or a bare list marker showed up — the SPA learned that (`frontend/src/lib/tasks.ts`), and this
/// port keeps the same single source of truth.
public enum MarkdownDocument {
    /// Parses already tag-stripped Markdown. Line numbers index the lines of `source`.
    public static func parse(_ source: String) -> [MarkdownNode] {
        let lines = source.components(separatedBy: "\n").enumerated().map { index, text in
            SourceLine(text: text.hasSuffix("\r") ? String(text.dropLast()) : text, index: index)
        }
        return parseBlocks(lines)
    }

    struct SourceLine: Sendable, Equatable {
        var text: String
        var index: Int
    }

    // MARK: - blocks

    static func parseBlocks(_ lines: [SourceLine]) -> [MarkdownNode] {
        var nodes: [MarkdownNode] = []
        var index = 0

        while index < lines.count {
            let (indent, body) = splitIndent(lines[index].text)
            if body.isEmpty {
                index += 1
                continue
            }

            if indent >= 4 {
                let block = indentedCode(lines, from: index)
                nodes.append(block.node)
                index = block.next
                continue
            }
            if let fence = fenceInfo(body) {
                let block = fencedCode(lines, from: index, fence: fence, indent: indent)
                nodes.append(block.node)
                index = block.next
                continue
            }
            if let heading = atxHeading(body) {
                nodes.append(
                    .heading(level: heading.level, source: heading.text, line: lines[index].index)
                )
                index += 1
                continue
            }
            if isThematicBreak(body) {
                nodes.append(.thematicBreak(line: lines[index].index))
                index += 1
                continue
            }
            if body.hasPrefix(">") {
                let block = blockquote(lines, from: index)
                nodes.append(block.node)
                index = block.next
                continue
            }
            if let table = tableBlock(lines, from: index) {
                nodes.append(table.node)
                index = table.next
                continue
            }
            if listMarker(body) != nil {
                let block = list(lines, from: index)
                nodes.append(block.node)
                index = block.next
                continue
            }
            let block = paragraph(lines, from: index)
            nodes.append(block.node)
            index = block.next
        }
        return nodes
    }

    private static func indentedCode(
        _ lines: [SourceLine],
        from start: Int
    ) -> (node: MarkdownNode, next: Int) {
        var texts: [String] = []
        var index = start
        var lastContent = start
        while index < lines.count {
            let (indent, body) = splitIndent(lines[index].text)
            if body.isEmpty {
                texts.append("")
                index += 1
                continue
            }
            if indent < 4 { break }
            texts.append(dropColumns(lines[index].text, 4))
            lastContent = index
            index += 1
        }
        let kept = texts.prefix(lastContent - start + 1)
        let text = kept.joined(separator: "\n") + "\n"
        return (.code(text: text, line: lines[start].index), lastContent + 1)
    }

    private static func fencedCode(
        _ lines: [SourceLine],
        from start: Int,
        fence: Fence,
        indent: Int
    ) -> (node: MarkdownNode, next: Int) {
        var texts: [String] = []
        var index = start + 1
        while index < lines.count {
            let (innerIndent, body) = splitIndent(lines[index].text)
            if innerIndent < 4, let closing = fenceInfo(body), closing.character == fence.character,
                closing.length >= fence.length, closing.info.isEmpty
            {
                index += 1
                break
            }
            texts.append(dropColumns(lines[index].text, indent))
            index += 1
        }
        let text = texts.isEmpty ? "" : texts.joined(separator: "\n") + "\n"
        return (.code(text: text, line: lines[start].index), index)
    }

    private static func blockquote(
        _ lines: [SourceLine],
        from start: Int
    ) -> (node: MarkdownNode, next: Int) {
        var inner: [SourceLine] = []
        var index = start
        while index < lines.count {
            let (indent, body) = splitIndent(lines[index].text)
            if indent < 4, body.hasPrefix(">") {
                var rest = String(body.dropFirst())
                if rest.hasPrefix(" ") || rest.hasPrefix("\t") { rest = String(rest.dropFirst()) }
                inner.append(SourceLine(text: rest, index: lines[index].index))
                index += 1
                continue
            }
            // A quote's paragraph may run on without its `>` (a lazy continuation), but nothing
            // that starts a block of its own belongs to the quote.
            if body.isEmpty || inner.isEmpty || isBlockStart(body) || listMarker(body) != nil {
                break
            }
            inner.append(SourceLine(text: body, index: lines[index].index))
            index += 1
        }
        return (.blockquote(children: parseBlocks(inner), line: lines[start].index), index)
    }

    private static func list(
        _ lines: [SourceLine],
        from start: Int
    ) -> (node: MarkdownNode, next: Int) {
        let (_, firstBody) = splitIndent(lines[start].text)
        guard let first = listMarker(firstBody) else {
            return (.paragraph(source: firstBody, line: lines[start].index), start + 1)
        }
        var items: [MarkdownListItem] = []
        var index = start

        while index < lines.count {
            let (markerIndent, body) = splitIndent(lines[index].text)
            guard markerIndent < 4, let marker = listMarker(body),
                marker.delimiter == first.delimiter, marker.ordered == first.ordered
            else { break }

            let contentIndent = markerIndent + marker.width + marker.spaces
            var itemLines: [SourceLine] = []
            if marker.hasContent {
                itemLines.append(
                    SourceLine(
                        text: dropColumns(lines[index].text, contentIndent),
                        index: lines[index].index
                    )
                )
            }
            var cursor = index + 1
            var sawBlank = false
            while cursor < lines.count {
                let (lineIndent, lineBody) = splitIndent(lines[cursor].text)
                if lineBody.isEmpty {
                    itemLines.append(SourceLine(text: "", index: lines[cursor].index))
                    sawBlank = true
                    cursor += 1
                    continue
                }
                if lineIndent >= contentIndent {
                    itemLines.append(
                        SourceLine(
                            text: dropColumns(lines[cursor].text, contentIndent),
                            index: lines[cursor].index
                        )
                    )
                    sawBlank = false
                    cursor += 1
                    continue
                }
                let isLazyContinuation =
                    !sawBlank && !itemLines.isEmpty && !isBlockStart(lineBody)
                    && listMarker(lineBody) == nil
                if isLazyContinuation {
                    itemLines.append(SourceLine(text: lineBody, index: lines[cursor].index))
                    cursor += 1
                    continue
                }
                break
            }
            while itemLines.last?.text.isEmpty == true { itemLines.removeLast() }
            items.append(makeItem(itemLines, markerLine: lines[index].index))
            index = cursor
        }
        return (.list(ordered: first.ordered, items: items, line: lines[start].index), index)
    }

    private static func makeItem(_ itemLines: [SourceLine], markerLine: Int) -> MarkdownListItem {
        var children = parseBlocks(itemLines)
        var contentLine = markerLine
        if case .paragraph(let source, let line) = children.first {
            contentLine = line
            if let task = taskPrefix(source) {
                children[0] = .paragraph(source: task.rest, line: line)
                return MarkdownListItem(
                    isTask: true,
                    checked: task.checked,
                    children: children,
                    contentLine: line
                )
            }
        }
        return MarkdownListItem(
            isTask: false,
            checked: false,
            children: children,
            contentLine: contentLine
        )
    }

    private static func tableBlock(
        _ lines: [SourceLine],
        from start: Int
    ) -> (node: MarkdownNode, next: Int)? {
        let (_, header) = splitIndent(lines[start].text)
        guard header.contains("|"), start + 1 < lines.count else { return nil }
        let (_, delimiter) = splitIndent(lines[start + 1].text)
        guard isDelimiterRow(delimiter) else { return nil }

        var rows: [[String]] = [splitRow(header)]
        var index = start + 2
        while index < lines.count {
            let (_, body) = splitIndent(lines[index].text)
            if body.isEmpty || !body.contains("|") { break }
            rows.append(splitRow(body))
            index += 1
        }
        return (.table(rows: rows, line: lines[start].index), index)
    }

    private static func paragraph(
        _ lines: [SourceLine],
        from start: Int
    ) -> (node: MarkdownNode, next: Int) {
        var texts: [String] = []
        var index = start
        while index < lines.count {
            let (indent, body) = splitIndent(lines[index].text)
            if body.isEmpty { break }
            if index > start, indent < 4 {
                if !texts.isEmpty, let level = setextLevel(body) {
                    return (
                        .heading(
                            level: level,
                            source: texts.joined(separator: "\n"),
                            line: lines[start].index
                        ),
                        index + 1
                    )
                }
                if isBlockStart(body) || listMarker(body) != nil { break }
            }
            texts.append(body)
            index += 1
        }
        return (.paragraph(source: texts.joined(separator: "\n"), line: lines[start].index), index)
    }

    // MARK: - line classification

    struct Fence {
        var character: Character
        var length: Int
        var info: String
    }

    struct ListMarkerInfo: Equatable {
        var ordered: Bool
        var delimiter: Character
        var width: Int
        var spaces: Int
        var hasContent: Bool
    }

    static func splitIndent(_ line: String) -> (columns: Int, body: String) {
        var columns = 0
        var index = line.startIndex
        while index < line.endIndex {
            if line[index] == " " {
                columns += 1
            } else if line[index] == "\t" {
                columns += 4 - (columns % 4)
            } else {
                break
            }
            index = line.index(after: index)
        }
        return (columns, String(line[index...]))
    }

    static func dropColumns(_ line: String, _ count: Int) -> String {
        var columns = 0
        var index = line.startIndex
        while index < line.endIndex, columns < count {
            if line[index] == "\t" {
                columns += 4 - (columns % 4)
            } else {
                columns += 1
            }
            index = line.index(after: index)
        }
        let padding = columns > count ? String(repeating: " ", count: columns - count) : ""
        return padding + String(line[index...])
    }

    static func fenceInfo(_ body: String) -> Fence? {
        guard let first = body.first, first == "`" || first == "~" else { return nil }
        var length = 0
        var index = body.startIndex
        while index < body.endIndex, body[index] == first {
            length += 1
            index = body.index(after: index)
        }
        guard length >= 3 else { return nil }
        let info = String(body[index...]).trimmingCharacters(in: .whitespaces)
        if first == "`", info.contains("`") { return nil }
        return Fence(character: first, length: length, info: info)
    }

    static func atxHeading(_ body: String) -> (level: Int, text: String)? {
        var level = 0
        var index = body.startIndex
        while index < body.endIndex, body[index] == "#", level < 7 {
            level += 1
            index = body.index(after: index)
        }
        guard (1...6).contains(level) else { return nil }
        if index < body.endIndex, body[index] != " ", body[index] != "\t" { return nil }
        var text = String(body[index...]).trimmingCharacters(in: .whitespaces)
        while text.hasSuffix("#") { text = String(text.dropLast()) }
        return (level, text.trimmingCharacters(in: .whitespaces))
    }

    static func isThematicBreak(_ body: String) -> Bool {
        guard let first = body.first, first == "-" || first == "*" || first == "_"
        else { return false }
        var count = 0
        for character in body {
            if character == first {
                count += 1
            } else if character != " " && character != "\t" {
                return false
            }
        }
        return count >= 3
    }

    static func setextLevel(_ body: String) -> Int? {
        guard let first = body.first, first == "=" || first == "-" else { return nil }
        guard body.allSatisfy({ $0 == first }) else { return nil }
        return first == "=" ? 1 : 2
    }

    static func isBlockStart(_ body: String) -> Bool {
        fenceInfo(body) != nil || atxHeading(body) != nil || isThematicBreak(body)
            || body.hasPrefix(">")
    }

    static func listMarker(_ body: String) -> ListMarkerInfo? {
        guard let first = body.first else { return nil }
        var width = 0
        var delimiter: Character
        var ordered: Bool

        if first == "-" || first == "+" || first == "*" {
            // `***` is a rule, not a bullet with two stars of content.
            if isThematicBreak(body) { return nil }
            width = 1
            delimiter = first
            ordered = false
        } else if first.isNumber {
            var digits = 0
            var index = body.startIndex
            while index < body.endIndex, body[index].isNumber, digits < 10 {
                digits += 1
                index = body.index(after: index)
            }
            guard digits <= 9, index < body.endIndex,
                body[index] == "." || body[index] == ")"
            else { return nil }
            width = digits + 1
            delimiter = body[index]
            ordered = true
        } else {
            return nil
        }

        let rest = String(body.dropFirst(width))
        if rest.isEmpty {
            return ListMarkerInfo(
                ordered: ordered,
                delimiter: delimiter,
                width: width,
                spaces: 1,
                hasContent: false
            )
        }
        let (spaces, remainder) = splitIndent(rest)
        guard spaces > 0 else { return nil }
        if remainder.isEmpty {
            return ListMarkerInfo(
                ordered: ordered,
                delimiter: delimiter,
                width: width,
                spaces: 1,
                hasContent: false
            )
        }
        // Five or more spaces put the content into an indented code block inside the item, so only
        // one of them belongs to the marker.
        return ListMarkerInfo(
            ordered: ordered,
            delimiter: delimiter,
            width: width,
            spaces: spaces >= 5 ? 1 : spaces,
            hasContent: true
        )
    }

    /// The task-list plugin's own test: the item's first paragraph starts with `[ ] `, `[x] ` or
    /// `[X] ` — the trailing space included, which is why `- [ ]nospace` and `- [ ]` are not
    /// tasks.
    static func taskPrefix(_ source: String) -> (checked: Bool, rest: String)? {
        for (marker, checked) in [("[ ] ", false), ("[x] ", true), ("[X] ", true)]
        where source.hasPrefix(marker) {
            return (checked, String(source.dropFirst(marker.count)))
        }
        return nil
    }

    static func isDelimiterRow(_ body: String) -> Bool {
        let cells = splitRow(body)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            var text = cell
            if text.hasPrefix(":") { text = String(text.dropFirst()) }
            if text.hasSuffix(":") { text = String(text.dropLast()) }
            return !text.isEmpty && text.allSatisfy { $0 == "-" }
        }
    }

    static func splitRow(_ body: String) -> [String] {
        var trimmed = body.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed = String(trimmed.dropFirst()) }
        if trimmed.hasSuffix("|"), !trimmed.hasSuffix("\\|") {
            trimmed = String(trimmed.dropLast())
        }
        var cells: [String] = []
        var current = ""
        var escaped = false
        for character in trimmed {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }
            if character == "\\" {
                escaped = true
                current.append(character)
                continue
            }
            if character == "|" {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
                continue
            }
            current.append(character)
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }
}
