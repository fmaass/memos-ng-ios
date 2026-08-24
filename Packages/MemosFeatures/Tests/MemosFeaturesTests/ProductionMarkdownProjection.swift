import Foundation
import MarkdownUI
import MemosCore

/// Projects what the app's renderer actually parsed into the parity block model.
///
/// The point of this file is that the parity fixture is checked against the RENDERER THE APP
/// SHIPS. `MarkdownContent(_:)` is the same parse `Markdown(_:)` performs — MarkdownUI has one
/// parser, `Array<BlockNode>(markdown:)` on cmark-gfm — so the block sequence projected here is
/// the block sequence the view renders. A guard fed by a second, hand-written parser can only
/// prove that the second parser agrees with the fixture; this one goes red when the shipped
/// renderer stops agreeing with it, which is the divergence that reaches a reader.
///
/// Two things it cannot see, both named at their assertion sites in `MarkdownRenderingTests`:
///
/// - `renderHTML()` applies cmark's own safe mode (`CMARK_OPT_DEFAULT` is safe since cmark-gfm
///   0.29), which blanks an unsafe `href` and replaces raw HTML with a comment. The VIEW does
///   neither: `AttributedStringInlineRenderer` puts the destination straight into
///   `attributes.link`, and an HTML node is rendered as literal text. So the raw-HTML case is not
///   projected here, and the link-liveness assertion is made against the rendered pixels instead
///   of against an `href`.
/// - the theme. Sizes, weights and colours are asserted by rendering, not by projecting.
enum ProductionMarkdownProjection {
    /// The projection of `markdown` as the app renders it: prepared exactly as `MemoMarkdownView`
    /// prepares it, parsed by the renderer the app ships.
    static func project(_ markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        project(HTMLElement.parse(html(markdown)), into: &blocks)
        return blocks
    }

    /// The renderer's own account of what it parsed. Quoted in a failure message, because the
    /// first question about a parity failure is always which side is wrong.
    static func html(_ markdown: String) -> String {
        MarkdownContent(MemoMarkdownSource.prepare(markdown)).renderHTML()
    }

    /// Every destination the RENDERER resolved out of this memo, prepared exactly as the view
    /// prepares it.
    ///
    /// Read off `renderMarkdown()` rather than `renderHTML()` on purpose: cmark's HTML renderer is
    /// safe by default and blanks an unsafe `href`, which would hide the very thing this is for.
    /// The CommonMark round trip keeps the destination the parser resolved, verbatim.
    static func destinations(in markdown: String) -> [String] {
        let prepared = MemoMarkdownSource.prepare(markdown)
        return destinations(ofRendered: MarkdownContent(prepared).renderMarkdown())
    }

    /// The same reading of a document the source layer never touched — what the renderer resolves
    /// when nothing has prepared it, which is the only thing a parser divergence can produce.
    static func destinations(ofRendered rendered: String) -> [String] {
        let chars = Array(rendered)
        var found: [String] = []
        var index = 0

        while index < chars.count {
            if chars[index] == "\\" {
                index += 2
                continue
            }
            if chars[index] == "]", index + 1 < chars.count, chars[index + 1] == "(" {
                let destination = readParenthesised(chars, from: index + 1)
                found.append(destination.text)
                index = destination.end
                continue
            }
            if chars[index] == "<", let autolink = readAutolink(chars, from: index) {
                found.append(autolink.text)
                index = autolink.end
                continue
            }
            index += 1
        }
        return found
    }

    private static func readParenthesised(
        _ chars: [Character],
        from start: Int
    ) -> (text: String, end: Int) {
        var depth = 0
        var destination = ""
        var index = start
        while index < chars.count {
            let character = chars[index]
            if character == "\\", index + 1 < chars.count {
                destination.append(chars[index + 1])
                index += 2
                continue
            }
            if character == "(" {
                depth += 1
                if depth > 1 { destination.append(character) }
                index += 1
                continue
            }
            if character == ")" {
                depth -= 1
                if depth == 0 {
                    index += 1
                    break
                }
                destination.append(character)
                index += 1
                continue
            }
            destination.append(character)
            index += 1
        }
        let trimmed = destination.trimmingCharacters(in: .whitespaces)
        let href = trimmed.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
        return (href.trimmingCharacters(in: CharacterSet(charactersIn: "<>")), index)
    }

    /// `<https://example.com>` — how the CommonMark writer puts a bare URL back.
    private static func readAutolink(
        _ chars: [Character],
        from start: Int
    ) -> (text: String, end: Int)? {
        var index = start + 1
        var destination = ""
        while index < chars.count, chars[index] != ">", !chars[index].isWhitespace {
            destination.append(chars[index])
            index += 1
        }
        guard index < chars.count, chars[index] == ">", destination.contains(":") else {
            return nil
        }
        return (destination, index + 1)
    }

    /// An empty paragraph is invisible in both clients, and the two renderers disagree on whether
    /// one is there at all: the SPA's sanitiser removes an image and leaves the `<p>` behind,
    /// while dropping the same construct from the source leaves cmark with no paragraph to make.
    /// Nothing a reader can see differs, so the comparison ignores them on both sides.
    static func ignoringInvisibleParagraphs(_ blocks: [MarkdownBlock]) -> [MarkdownBlock] {
        blocks.filter { block in
            !(block.type == .paragraph && block.text.isEmpty && block.links.isEmpty
                && block.inline.isEmpty)
        }
    }

    private static func project(_ nodes: [HTMLNode], into blocks: inout [MarkdownBlock]) {
        for case .element(let element) in nodes {
            switch element.tag {
            case "h1", "h2", "h3", "h4", "h5", "h6":
                let inline = inlineContent(of: element)
                blocks.append(
                    MarkdownBlock(
                        type: .heading,
                        text: inline.text,
                        links: inline.links,
                        inline: inline.spans,
                        level: Int(element.tag.dropFirst()) ?? 1
                    )
                )
            case "p":
                let inline = inlineContent(of: element)
                blocks.append(
                    MarkdownBlock(
                        type: .paragraph,
                        text: inline.text,
                        links: inline.links,
                        inline: inline.spans
                    )
                )
            case "pre":
                // Verbatim: no NFC, no whitespace collapsing, no trim.
                blocks.append(MarkdownBlock(type: .code, text: element.rawText))
            case "hr":
                blocks.append(MarkdownBlock(type: .hr, text: ""))
            case "blockquote":
                let inline = flatten(element)
                blocks.append(
                    MarkdownBlock(
                        type: .blockquote,
                        text: inline.text,
                        links: inline.links,
                        inline: inline.spans
                    )
                )
            case "ul", "ol":
                projectList(element, level: 0, into: &blocks)
            case "table":
                projectTable(element, into: &blocks)
            default:
                continue
            }
        }
    }

    private static func projectTable(_ table: HTMLElement, into blocks: inout [MarkdownBlock]) {
        var rows: [[String]] = []
        var links: [MarkdownLink] = []
        var spans: [MarkdownSpan] = []
        for row in table.descendants(named: "tr") {
            var cells: [String] = []
            for cell in row.children(namedAnyOf: ["th", "td"]) {
                let inline = inlineContent(of: cell)
                cells.append(inline.text)
                links += inline.links
                spans += inline.spans
            }
            rows.append(cells)
        }
        blocks.append(
            MarkdownBlock(type: .table, text: "", links: links, inline: spans, rows: rows)
        )
    }

    /// Mirrors the schema's list rule: a run of consecutive non-task items is one `list` block, a
    /// task or a sublist breaks the run, and a sublist's blocks follow the item that holds it one
    /// level deeper.
    private static func projectList(
        _ list: HTMLElement,
        level: Int,
        into blocks: inout [MarkdownBlock]
    ) {
        let ordered = list.tag == "ol"
        var run: [String] = []
        var runLinks: [MarkdownLink] = []
        var runSpans: [MarkdownSpan] = []

        func flushRun() {
            guard !run.isEmpty else { return }
            blocks.append(
                MarkdownBlock(
                    type: .list,
                    text: "",
                    links: runLinks,
                    inline: runSpans,
                    level: level,
                    ordered: ordered,
                    items: run
                )
            )
            run = []
            runLinks = []
            runSpans = []
        }

        for item in list.children(namedAnyOf: ["li"]) {
            var sublists: [HTMLElement] = []
            var own = item
            own.nodes = item.nodes.filter { node in
                guard case .element(let child) = node else { return true }
                if child.tag == "ul" || child.tag == "ol" {
                    sublists.append(child)
                    return false
                }
                return true
            }
            let checkbox = own.descendants(named: "input")
                .first { $0.attributes["type"] == "checkbox" }
            let inline = inlineContent(of: own)

            if let checkbox {
                flushRun()
                blocks.append(
                    MarkdownBlock(
                        type: .task,
                        text: inline.text,
                        links: inline.links,
                        inline: inline.spans,
                        level: level,
                        ordered: ordered,
                        checked: checkbox.attributes["checked"] != nil
                    )
                )
            } else {
                run.append(inline.text)
                runLinks += inline.links
                runSpans += inline.spans
            }

            if !sublists.isEmpty {
                flushRun()
                for sublist in sublists {
                    projectList(sublist, level: level + 1, into: &blocks)
                }
            }
        }
        flushRun()
    }

    /// Collapses a subtree to one run of text — what a blockquote projects to. Structure inside a
    /// quote is a known limitation of schema 1.
    private static func flatten(_ element: HTMLElement) -> InlineContent {
        var result = InlineContent()
        for case .element(let child) in element.nodes {
            var piece = InlineContent()
            switch child.tag {
            case "h1", "h2", "h3", "h4", "h5", "h6", "p":
                piece = inlineContent(of: child)
            case "pre":
                piece.raw = child.rawText
            case "hr":
                continue
            case "li":
                // A list item's own text is inline content, not a child block — walking only the
                // element children of the item would flatten a quoted list to nothing at all.
                piece = inlineContent(of: child)
            default:
                piece = flatten(child)
            }
            if !result.raw.isEmpty { result.raw += " " }
            result.raw += piece.raw
            result.spans += piece.spans
            result.links += piece.links
        }
        return result
    }

    private struct InlineContent {
        var raw = ""
        var spans: [MarkdownSpan] = []
        var links: [MarkdownLink] = []

        var text: String { MarkdownInline.normalize(foldSoftBreaks(raw)) }
    }

    private static func inlineContent(of element: HTMLElement) -> InlineContent {
        var out = InlineContent()
        collectInline(element, into: &out)
        return out
    }

    private static func collectInline(_ element: HTMLElement, into out: inout InlineContent) {
        for node in element.nodes {
            switch node {
            case .text(let text):
                out.raw += text
            case .element(let child):
                switch child.tag {
                case "br":
                    out.raw.append(breakMarker)
                case "input", "img":
                    continue
                case "code":
                    var inner = InlineContent()
                    collectInline(child, into: &inner)
                    out.spans.append(MarkdownSpan(type: .code, text: inner.text))
                    out.raw += inner.raw
                case "strong", "b", "em", "i", "del", "s":
                    var inner = InlineContent()
                    collectInline(child, into: &inner)
                    let kind: MarkdownSpan.Kind =
                        switch child.tag {
                        case "strong", "b": .strong
                        case "em", "i": .em
                        default: .strike
                        }
                    // Pre-order: the outer span first, then the ones nested inside it.
                    out.spans.append(MarkdownSpan(type: kind, text: inner.text))
                    out.raw += inner.raw
                    out.spans += inner.spans
                    out.links += inner.links
                case "a":
                    var inner = InlineContent()
                    collectInline(child, into: &inner)
                    let href = child.attributes["href"] ?? ""
                    // Only the schemes DOMPurify leaves tappable are ever listed; anything else
                    // contributes its text and nothing more.
                    if MarkdownInline.isTappableScheme(href) {
                        out.links.append(MarkdownLink(href: href, text: inner.text))
                    }
                    out.raw += inner.raw
                    out.spans += inner.spans
                    out.links += inner.links
                default:
                    collectInline(child, into: &out)
                }
            }
        }
    }

    /// Stands in for a `<br>` while text is assembled — the same marker
    /// `MarkdownInline.normalize` reads, so the collapsing rules are the schema's and are written
    /// once.
    private static let breakMarker: Character = "\u{0}"

    /// The view renders a soft break as a line break (`markdownSoftBreakMode(.lineBreak)`, which
    /// is what the SPA's `breaks: true` does), so a newline inside inline text is a break and not
    /// whitespace. The newlines cmark puts BETWEEN tags are not: they sit at the ends of a run and
    /// are trimmed, or they hug a `<br>` and are absorbed into it.
    private static func foldSoftBreaks(_ raw: String) -> String {
        let body = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var out = ""
        var index = body.startIndex
        while index < body.endIndex {
            let character = body[index]
            guard character.isWhitespace || character == breakMarker else {
                out.append(character)
                index = body.index(after: index)
                continue
            }
            var markers = 0
            var sawNewline = false
            while index < body.endIndex,
                body[index].isWhitespace || body[index] == breakMarker
            {
                if body[index] == breakMarker { markers += 1 }
                if body[index] == "\n" { sawNewline = true }
                index = body.index(after: index)
            }
            if markers > 0 {
                out += String(repeating: String(breakMarker), count: markers)
            } else if sawNewline {
                out.append(breakMarker)
            } else {
                out.append(" ")
            }
        }
        return out
    }
}

// MARK: - Just enough HTML to read cmark's output

enum HTMLNode {
    case text(String)
    case element(HTMLElement)
}

struct HTMLElement {
    var tag: String
    var attributes: [String: String] = [:]
    var nodes: [HTMLNode] = []

    /// Every character of text below this element, entities resolved and nothing else touched —
    /// what a `<pre>` projects verbatim.
    var rawText: String {
        nodes.reduce(into: "") { text, node in
            switch node {
            case .text(let value): text += value
            case .element(let child): text += child.rawText
            }
        }
    }

    func children(namedAnyOf tags: Set<String>) -> [HTMLElement] {
        nodes.compactMap { node in
            guard case .element(let child) = node, tags.contains(child.tag) else { return nil }
            return child
        }
    }

    func descendants(named tag: String) -> [HTMLElement] {
        nodes.flatMap { node -> [HTMLElement] in
            guard case .element(let child) = node else { return [] }
            return (child.tag == tag ? [child] : []) + child.descendants(named: tag)
        }
    }

    /// cmark's HTML is machine-written and regular: no unclosed tags outside the void set, no
    /// attribute minimisation beyond `disabled=""`, no scripts. A general HTML parser would be
    /// more code and no more correct here.
    static func parse(_ html: String) -> [HTMLNode] {
        var parser = HTMLParser(chars: Array(html))
        return parser.parseNodes(until: nil)
    }
}

private let voidTags: Set<String> = ["br", "hr", "img", "input", "meta", "link"]

private struct HTMLParser {
    let chars: [Character]
    var index = 0

    mutating func parseNodes(until closing: String?) -> [HTMLNode] {
        var nodes: [HTMLNode] = []
        var text = ""

        func flushText() {
            if !text.isEmpty {
                nodes.append(.text(decodeEntities(text)))
                text = ""
            }
        }

        while index < chars.count {
            guard chars[index] == "<" else {
                text.append(chars[index])
                index += 1
                continue
            }
            if startsComment() {
                skipComment()
                continue
            }
            if let name = peekClosingTag() {
                flushText()
                if name == closing {
                    skipClosingTag()
                    return nodes
                }
                // A stray close tag for something else: let the caller handle it.
                return nodes
            }
            guard let open = readOpeningTag() else {
                text.append(chars[index])
                index += 1
                continue
            }
            flushText()
            var element = HTMLElement(tag: open.tag, attributes: open.attributes)
            if !open.selfClosing, !voidTags.contains(open.tag) {
                element.nodes = parseNodes(until: open.tag)
            }
            nodes.append(.element(element))
        }
        flushText()
        return nodes
    }

    private func startsComment() -> Bool {
        index + 3 < chars.count && chars[index + 1] == "!" && chars[index + 2] == "-"
            && chars[index + 3] == "-"
    }

    private mutating func skipComment() {
        index += 4
        while index + 2 < chars.count {
            if chars[index] == "-" && chars[index + 1] == "-" && chars[index + 2] == ">" {
                index += 3
                return
            }
            index += 1
        }
        index = chars.count
    }

    private func peekClosingTag() -> String? {
        guard index + 1 < chars.count, chars[index + 1] == "/" else { return nil }
        var cursor = index + 2
        var name = ""
        while cursor < chars.count, chars[cursor] != ">" {
            name.append(chars[cursor])
            cursor += 1
        }
        return name.trimmingCharacters(in: .whitespaces).lowercased()
    }

    private mutating func skipClosingTag() {
        while index < chars.count, chars[index] != ">" { index += 1 }
        if index < chars.count { index += 1 }
    }

    private mutating func readOpeningTag()
        -> (tag: String, attributes: [String: String], selfClosing: Bool)?
    {
        let start = index
        var cursor = index + 1
        var name = ""
        while cursor < chars.count, !chars[cursor].isWhitespace, chars[cursor] != ">",
            chars[cursor] != "/"
        {
            name.append(chars[cursor])
            cursor += 1
        }
        guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber }) else {
            index = start
            return nil
        }

        var attributes: [String: String] = [:]
        var selfClosing = false
        while cursor < chars.count, chars[cursor] != ">" {
            if chars[cursor].isWhitespace {
                cursor += 1
                continue
            }
            if chars[cursor] == "/" {
                selfClosing = true
                cursor += 1
                continue
            }
            var key = ""
            while cursor < chars.count, !chars[cursor].isWhitespace, chars[cursor] != "=",
                chars[cursor] != ">", chars[cursor] != "/"
            {
                key.append(chars[cursor])
                cursor += 1
            }
            var value = ""
            if cursor < chars.count, chars[cursor] == "=" {
                cursor += 1
                if cursor < chars.count, chars[cursor] == "\"" || chars[cursor] == "'" {
                    let quote = chars[cursor]
                    cursor += 1
                    while cursor < chars.count, chars[cursor] != quote {
                        value.append(chars[cursor])
                        cursor += 1
                    }
                    if cursor < chars.count { cursor += 1 }
                } else {
                    while cursor < chars.count, !chars[cursor].isWhitespace, chars[cursor] != ">" {
                        value.append(chars[cursor])
                        cursor += 1
                    }
                }
            }
            attributes[key.lowercased()] = decodeEntities(value)
        }
        if cursor < chars.count { cursor += 1 }
        index = cursor
        return (name.lowercased(), attributes, selfClosing)
    }
}

private func decodeEntities(_ text: String) -> String {
    guard text.contains("&") else { return text }
    var out = ""
    var rest = Substring(text)
    while let start = rest.firstIndex(of: "&") {
        out += rest[rest.startIndex..<start]
        rest = rest[rest.index(after: start)...]
        guard let end = rest.firstIndex(of: ";"), rest.distance(from: rest.startIndex, to: end) <= 8
        else {
            out.append("&")
            continue
        }
        let name = String(rest[rest.startIndex..<end])
        rest = rest[rest.index(after: end)...]
        switch name {
        case "amp": out.append("&")
        case "lt": out.append("<")
        case "gt": out.append(">")
        case "quot": out.append("\"")
        case "apos": out.append("'")
        default:
            if name.hasPrefix("#x") || name.hasPrefix("#X"),
                let value = UInt32(name.dropFirst(2), radix: 16),
                let scalar = Unicode.Scalar(value)
            {
                out.append(Character(scalar))
            } else if name.hasPrefix("#"), let value = UInt32(name.dropFirst()),
                let scalar = Unicode.Scalar(value)
            {
                out.append(Character(scalar))
            } else {
                out += "&\(name);"
            }
        }
    }
    out += rest
    return out
}
