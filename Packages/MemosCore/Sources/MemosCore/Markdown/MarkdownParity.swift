import Foundation

/// One block of the projection defined by `docs/markdown-parity.schema.md` (schema 1).
///
/// This is the shape both renderers are compared in. Comparing HTML would fail on formatting two
/// engines will never agree on; comparing this fails only when the app actually renders something
/// else — a lost task state, a flattened list, a link that stayed tappable when the SPA made it
/// plain text.
public struct MarkdownBlock: Sendable, Equatable, Codable {
    public enum Kind: String, Sendable, Equatable, Codable {
        case heading
        case paragraph
        case list
        case task
        case code
        case blockquote
        case table
        case hr
    }

    public var type: Kind
    public var text: String
    public var links: [MarkdownLink]
    public var inline: [MarkdownSpan]
    public var level: Int?
    public var ordered: Bool?
    public var checked: Bool?
    public var items: [String]?
    public var rows: [[String]]?

    public init(
        type: Kind,
        text: String,
        links: [MarkdownLink] = [],
        inline: [MarkdownSpan] = [],
        level: Int? = nil,
        ordered: Bool? = nil,
        checked: Bool? = nil,
        items: [String]? = nil,
        rows: [[String]]? = nil
    ) {
        self.type = type
        self.text = text
        self.links = links
        self.inline = inline
        self.level = level
        self.ordered = ordered
        self.checked = checked
        self.items = items
        self.rows = rows
    }
}

/// The app's side of the parity contract.
public enum MarkdownParity {
    /// Projects memo Markdown into the block sequence the fixture pins.
    public static func project(_ markdown: String) -> [MarkdownBlock] {
        let nodes = MarkdownDocument.parse(stripTagOnlyLines(markdown))
        var blocks: [MarkdownBlock] = []
        project(nodes, into: &blocks)
        return blocks
    }

    private static func project(_ nodes: [MarkdownNode], into blocks: inout [MarkdownBlock]) {
        for node in nodes {
            switch node {
            case .heading(let level, let source, _):
                let inline = MarkdownInline.parse(source)
                blocks.append(
                    MarkdownBlock(
                        type: .heading,
                        text: inline.text,
                        links: inline.links,
                        inline: inline.spans,
                        level: level
                    )
                )
            case .paragraph(let source, _):
                let inline = MarkdownInline.parse(source)
                blocks.append(
                    MarkdownBlock(
                        type: .paragraph,
                        text: inline.text,
                        links: inline.links,
                        inline: inline.spans
                    )
                )
            case .code(let text, _):
                // Verbatim: no NFC, no whitespace collapsing, no trim.
                blocks.append(MarkdownBlock(type: .code, text: text))
            case .thematicBreak:
                blocks.append(MarkdownBlock(type: .hr, text: ""))
            case .blockquote(let children, _):
                let inline = flatten(children)
                blocks.append(
                    MarkdownBlock(
                        type: .blockquote,
                        text: inline.text,
                        links: inline.links,
                        inline: inline.spans
                    )
                )
            case .list(let ordered, let items, _):
                projectList(ordered: ordered, items: items, level: 0, into: &blocks)
            case .table(let rows, _):
                var cellTexts: [[String]] = []
                var links: [MarkdownLink] = []
                var spans: [MarkdownSpan] = []
                for row in rows {
                    var texts: [String] = []
                    for cell in row {
                        let inline = MarkdownInline.parse(cell)
                        texts.append(inline.text)
                        links += inline.links
                        spans += inline.spans
                    }
                    cellTexts.append(texts)
                }
                blocks.append(
                    MarkdownBlock(
                        type: .table,
                        text: "",
                        links: links,
                        inline: spans,
                        rows: cellTexts
                    )
                )
            }
        }
    }

    /// A run of consecutive non-task items projects as one `list` block; a task, or a sublist
    /// hanging off an item, breaks the run so that the order alone still says which item a
    /// sublist belongs to.
    private static func projectList(
        ordered: Bool,
        items: [MarkdownListItem],
        level: Int,
        into blocks: inout [MarkdownBlock]
    ) {
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

        for item in items {
            var own: [MarkdownNode] = []
            var sublists: [(ordered: Bool, items: [MarkdownListItem])] = []
            for child in item.children {
                if case .list(let childOrdered, let childItems, _) = child {
                    sublists.append((childOrdered, childItems))
                } else {
                    own.append(child)
                }
            }
            let inline = flatten(own)

            if item.isTask {
                flushRun()
                blocks.append(
                    MarkdownBlock(
                        type: .task,
                        text: inline.text,
                        links: inline.links,
                        inline: inline.spans,
                        level: level,
                        ordered: ordered,
                        checked: item.checked
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
                    projectList(
                        ordered: sublist.ordered,
                        items: sublist.items,
                        level: level + 1,
                        into: &blocks
                    )
                }
            }
        }
        flushRun()
    }

    /// Collapses a subtree to one run of text — what a blockquote projects to, and what a list
    /// item's own text is. Structure inside a quote is a known limitation of schema 1.
    private static func flatten(_ nodes: [MarkdownNode]) -> MarkdownInlineResult {
        var result = MarkdownInlineResult()
        for node in nodes {
            var piece = MarkdownInlineResult()
            switch node {
            case .heading(_, let source, _), .paragraph(let source, _):
                piece = MarkdownInline.parse(source)
            case .code(let text, _):
                piece.raw = text
            case .thematicBreak:
                continue
            case .blockquote(let children, _):
                piece = flatten(children)
            case .list(_, let items, _):
                piece = flatten(items.flatMap(\.children))
            case .table(let rows, _):
                let cells = rows.flatMap { $0 }
                piece = flatten(cells.map { MarkdownNode.paragraph(source: $0, line: 0) })
            }
            if !result.raw.isEmpty { result.raw += " " }
            result.raw += piece.raw
            result.spans += piece.spans
            result.links += piece.links
        }
        return result
    }
}

/// The committed fixture: every case carries its own Markdown input, so the app never needs the
/// SPA to reproduce the expected output.
public struct MarkdownParityFixture: Sendable, Decodable {
    public struct Case: Sendable, Decodable {
        public var id: String
        public var markdown: String
        public var projection: [MarkdownBlock]
    }

    public var schema: Int
    public var generator: String
    public var cases: [Case]

    public static func decode(from data: Data) throws -> MarkdownParityFixture {
        try JSONDecoder().decode(MarkdownParityFixture.self, from: data)
    }
}
