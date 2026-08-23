import Foundation

// Ported from `frontend/src/lib/tasks.ts` with the same test vectors.
//
// Which lines become checkboxes is decided by the PARSER, not by a line-shaped regex: `> - [ ] q`
// and `1. [ ] o` do render a checkbox, while a literal `- [ ] x` inside a fence or an indented
// code block does not, and neither does `- [ ]x`. A regex that disagrees on any of those makes the
// rendered index point at the wrong source line — and a wrong index means the app checks off a
// different task than the one the reader tapped.

/// Class the SPA's task-list plugin puts on every rendered checkbox. Kept so both sides can be
/// talked about in the same terms.
public let taskCheckboxClass = "task-list-item-checkbox"

/// Source line indices (0-based, into `content.split("\n")`) of the tasks the renderer turns into
/// checkboxes, in rendered document order.
public func taskCheckboxLines(_ content: String) -> [Int] {
    // The renderer parses the tag-stripped source, so parsed line numbers index the stripped
    // document; this keeps the map back to the caller's line numbers.
    var sourceLineOf: [Int] = []
    var kept: [String] = []
    let allLines = content.components(separatedBy: "\n")
    for (index, line) in allLines.enumerated() where !isTagOnlyLine(line) {
        sourceLineOf.append(index)
        kept.append(line)
    }

    var lines: [Int] = []
    collectTaskLines(MarkdownDocument.parse(kept.joined(separator: "\n")), into: &lines)
    return lines.compactMap { strippedLine in
        strippedLine < sourceLineOf.count ? sourceLineOf[strippedLine] : nil
    }
}

/// The rendered checkboxes of a memo, in rendered document order — the companion of
/// `taskCheckboxLines`, so element N of one describes element N of the other.
///
/// It reads the document tree rather than the parity projection because schema 1 deliberately
/// flattens a blockquote to one text block: `> - [ ] q` DOES render a checkbox, and a reader who
/// can see it must be able to see its state.
public func taskCheckboxItems(_ content: String) -> [(text: String, checked: Bool)] {
    var items: [(text: String, checked: Bool)] = []
    collectTaskItems(MarkdownDocument.parse(stripTagOnlyLines(content)), into: &items)
    return items
}

private func collectTaskItems(
    _ nodes: [MarkdownNode],
    into items: inout [(text: String, checked: Bool)]
) {
    for node in nodes {
        switch node {
        case .list(_, let listItems, _):
            for item in listItems {
                if item.isTask {
                    items.append((text: ownText(of: item.children), checked: item.checked))
                }
                collectTaskItems(item.children, into: &items)
            }
        case .blockquote(let children, _):
            collectTaskItems(children, into: &items)
        case .heading, .paragraph, .code, .thematicBreak, .table:
            continue
        }
    }
}

/// A list item's own text: what it says, not what its sublists say.
private func ownText(of children: [MarkdownNode]) -> String {
    var raw = ""
    for child in children {
        switch child {
        case .paragraph(let source, _), .heading(_, let source, _):
            if !raw.isEmpty { raw += " " }
            raw += MarkdownInline.parse(source).raw
        case .code(let text, _):
            if !raw.isEmpty { raw += " " }
            raw += text
        case .list, .blockquote, .thematicBreak, .table:
            continue
        }
    }
    return MarkdownInline.normalize(raw)
}

private func collectTaskLines(_ nodes: [MarkdownNode], into lines: inout [Int]) {
    for node in nodes {
        switch node {
        case .list(_, let items, _):
            for item in items {
                if item.isTask { lines.append(item.contentLine) }
                collectTaskLines(item.children, into: &lines)
            }
        case .blockquote(let children, _):
            collectTaskLines(children, into: &lines)
        case .heading, .paragraph, .code, .thematicBreak, .table:
            continue
        }
    }
}

// On a line the parser certified as a task, everything before the checkbox is indentation,
// blockquote markers and the list marker — none of which can contain `[` — so the first
// `[ ]`/`[x]` after a list marker is the checkbox. Replacing only the mark keeps the `> `
// prefix, the indentation and the bullet style intact.
private let checkboxMarkPattern =
    "^([^\\[\\n]*?(?:[-*+]|\\d{1,9}[.)])[ \\t]+\\[)([ xX])(\\])"
// A list marker may sit on its OWN line, with the item's first content — the checkbox —
// indented on the next one. The line is parser-certified, so when no marker precedes the box
// on it, the box that opens the line's content is the checkbox.
private let continuationMarkPattern = "^((?:[ \\t]|>[ \\t]?)*\\[)([ xX])(\\])"

/// Toggles the Nth rendered checkbox (`- [ ]` ↔ `- [x]`), N being its index among the rendered
/// checkboxes. Pure, so the toggle is unit-tested rather than driven through a view.
public func toggleTask(_ content: String, at index: Int) -> String {
    let targets = taskCheckboxLines(content)
    guard index >= 0, index < targets.count else { return content }
    let target = targets[index]
    var lines = content.components(separatedBy: "\n")
    guard target < lines.count else { return content }
    let line = lines[target]

    // If neither pattern matches an enumerated line the content is left alone — a silent no-op
    // beats corrupting a line whose shape we did not recognise.
    guard
        let replaced = flipMark(in: line, pattern: checkboxMarkPattern)
            ?? flipMark(in: line, pattern: continuationMarkPattern)
    else { return content }
    lines[target] = replaced
    return lines.joined(separator: "\n")
}

private func flipMark(in line: String, pattern: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let range = NSRange(line.startIndex..<line.endIndex, in: line)
    guard let match = regex.firstMatch(in: line, range: range), match.numberOfRanges == 4,
        let prefix = Range(match.range(at: 1), in: line),
        let mark = Range(match.range(at: 2), in: line),
        let suffix = Range(match.range(at: 3), in: line)
    else { return nil }
    let flipped = line[mark] == " " ? "x" : " "
    return String(line[line.startIndex..<prefix.lowerBound]) + line[prefix] + flipped + line[suffix]
        + line[suffix.upperBound...]
}
