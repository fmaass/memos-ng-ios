import Foundation

/// A styled run inside a block: `**strong**`, `_em_`, `~~strike~~`, `` `code` ``.
public struct MarkdownSpan: Sendable, Equatable, Codable {
    public enum Kind: String, Sendable, Equatable, Codable {
        case strong
        case em
        case strike
        case code
    }

    public var type: Kind
    public var text: String

    public init(type: Kind, text: String) {
        self.type = type
        self.text = text
    }
}

/// A link the reader may follow. Only schemes the SPA leaves tappable ever reach here.
public struct MarkdownLink: Sendable, Equatable, Codable {
    public var href: String
    public var text: String

    public init(href: String, text: String) {
        self.href = href
        self.text = text
    }
}

/// What one run of inline Markdown produced.
public struct MarkdownInlineResult: Sendable, Equatable {
    /// Text with soft breaks still marked, before normalisation.
    public var raw: String = ""
    public var spans: [MarkdownSpan] = []
    public var links: [MarkdownLink] = []

    public var text: String { MarkdownInline.normalize(raw) }
}

/// The inline half of the renderer contract.
///
/// The rules here are the SPA's, not CommonMark's in general: raw HTML is literal text
/// (`html: false`), a single newline is a line break (`breaks: true`), bare URLs and e-mail
/// addresses become links (`linkify`), and a link is only a link when its scheme survives
/// markdown-it's `validateLink` — a `javascript:` or `data:` destination leaves the whole
/// `[text](href)` on screen as the literal characters the author typed.
public enum MarkdownInline {
    /// Stands in for a `<br>` while text is assembled, so that a soft break can be told apart
    /// from the ordinary whitespace that collapses around it.
    static let breakMarker: Character = "\u{0}"

    public static func parse(_ source: String) -> MarkdownInlineResult {
        let parser = Parser(chars: Array(source))
        return parser.parse(from: 0, to: parser.chars.count)
    }

    /// Collapses text the way the projection defines it: `<br>` becomes `\n`, every other
    /// whitespace run becomes one space, whitespace hugging a `\n` disappears, the result is
    /// trimmed and normalised to Unicode NFC.
    public static func normalize(_ raw: String) -> String {
        var result = ""
        var pendingSpace = false
        var atSegmentStart = true
        for character in raw {
            if character == breakMarker {
                pendingSpace = false
                result.append("\n")
                atSegmentStart = true
                continue
            }
            if character.isWhitespace {
                if !atSegmentStart { pendingSpace = true }
                continue
            }
            if pendingSpace {
                result.append(" ")
                pendingSpace = false
            }
            result.append(character)
            atSegmentStart = false
        }
        return result.precomposedStringWithCanonicalMapping
    }

    /// markdown-it's `validateLink`: the schemes it refuses to build a link from at all.
    static func isAllowedDestination(_ href: String) -> Bool {
        let lowered = href.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for scheme in ["javascript:", "vbscript:", "file:"] where lowered.hasPrefix(scheme) {
            return false
        }
        if lowered.hasPrefix("data:") {
            // markdown-it allows only a handful of image data URLs through.
            let allowed = [
                "data:image/gif;", "data:image/png;", "data:image/jpeg;", "data:image/webp;",
            ]
            return allowed.contains { lowered.hasPrefix($0) }
        }
        return true
    }

    /// DOMPurify's `ALLOWED_URI_REGEXP`: what stays tappable after sanitising.
    public static func isTappableScheme(_ href: String) -> Bool {
        let lowered = href.lowercased()
        return lowered.hasPrefix("http:") || lowered.hasPrefix("https:")
            || lowered.hasPrefix("mailto:")
    }
}

extension MarkdownInline {
    fileprivate struct Parser {
        let chars: [Character]

        func parse(from lo: Int, to hi: Int) -> MarkdownInlineResult {
            var out = MarkdownInlineResult()
            var literal = ""
            var index = lo

            func flush() {
                guard !literal.isEmpty else { return }
                let linkified = Linkify.scan(literal)
                out.raw += linkified.raw
                out.links += linkified.links
                literal = ""
            }

            while index < hi {
                let character = chars[index]

                if character == "\\", index + 1 < hi, chars[index + 1].isMarkdownPunctuation {
                    literal.append(chars[index + 1])
                    index += 2
                    continue
                }
                if character == "\n" {
                    flush()
                    out.raw.append(MarkdownInline.breakMarker)
                    index += 1
                    continue
                }
                if character == "`", let span = codeSpan(at: index, hi: hi) {
                    flush()
                    out.raw += span.text
                    let text = MarkdownInline.normalize(span.text)
                    out.spans.append(MarkdownSpan(type: .code, text: text))
                    index = span.end
                    continue
                }
                if character == "!", index + 1 < hi, chars[index + 1] == "[",
                    let image = bracketed(at: index + 1, hi: hi)
                {
                    // An image is dropped whole: `img` is not in the sanitiser's allowlist, and a
                    // removed void element takes its alt text with it.
                    flush()
                    index = image.end
                    continue
                }
                if character == "[", let link = bracketed(at: index, hi: hi) {
                    flush()
                    if MarkdownInline.isAllowedDestination(link.destination) {
                        let inner = parse(from: link.labelStart, to: link.labelEnd)
                        out.raw += inner.raw
                        out.spans += inner.spans
                        out.links += inner.links
                        if MarkdownInline.isTappableScheme(link.destination) {
                            out.links.append(
                                MarkdownLink(href: link.destination, text: inner.text)
                            )
                        }
                    } else {
                        // markdown-it never builds the link, so the source stays on screen.
                        out.raw += String(chars[index..<link.end])
                    }
                    index = link.end
                    continue
                }
                if let emphasis = emphasis(at: index, hi: hi) {
                    flush()
                    let inner = parse(from: emphasis.contentStart, to: emphasis.contentEnd)
                    out.raw += inner.raw
                    out.spans.append(
                        MarkdownSpan(type: emphasis.kind, text: MarkdownInline.normalize(inner.raw))
                    )
                    out.spans += inner.spans
                    out.links += inner.links
                    index = emphasis.end
                    continue
                }

                literal.append(character)
                index += 1
            }
            flush()
            return out
        }

        // MARK: - code spans

        private func codeSpan(at start: Int, hi: Int) -> (text: String, end: Int)? {
            var openLength = 0
            var index = start
            while index < hi, chars[index] == "`" {
                openLength += 1
                index += 1
            }
            let contentStart = index
            while index < hi {
                if chars[index] == "`" {
                    var runLength = 0
                    let runStart = index
                    while index < hi, chars[index] == "`" {
                        runLength += 1
                        index += 1
                    }
                    if runLength == openLength {
                        var content = String(chars[contentStart..<runStart])
                        // CommonMark strips one space from each end of a padded code span.
                        if content.count >= 2, content.hasPrefix(" "), content.hasSuffix(" "),
                            content.contains(where: { $0 != " " })
                        {
                            content = String(content.dropFirst().dropLast())
                        }
                        return (content, index)
                    }
                    continue
                }
                index += 1
            }
            return nil
        }

        // MARK: - links and images

        private struct Bracketed {
            var labelStart: Int
            var labelEnd: Int
            var destination: String
            var end: Int
        }

        /// Matches `[label](destination)` starting at the `[`, with balanced parentheses in the
        /// destination so that `[js](javascript:alert(1))` is one construct, not two.
        private func bracketed(at start: Int, hi: Int) -> Bracketed? {
            guard start < hi, chars[start] == "[" else { return nil }
            var depth = 0
            var index = start
            var labelEnd = -1
            while index < hi {
                let character = chars[index]
                if character == "\\" {
                    index += 2
                    continue
                }
                if character == "[" { depth += 1 }
                if character == "]" {
                    depth -= 1
                    if depth == 0 {
                        labelEnd = index
                        break
                    }
                }
                index += 1
            }
            guard labelEnd > start, labelEnd + 1 < hi, chars[labelEnd + 1] == "("
            else { return nil }

            var parenDepth = 0
            var destination = ""
            index = labelEnd + 1
            while index < hi {
                let character = chars[index]
                if character == "\\", index + 1 < hi {
                    destination.append(chars[index + 1])
                    index += 2
                    continue
                }
                if character == "(" {
                    parenDepth += 1
                    if parenDepth > 1 { destination.append(character) }
                    index += 1
                    continue
                }
                if character == ")" {
                    parenDepth -= 1
                    if parenDepth == 0 {
                        // A title (`[a](b "t")`) is not projected, so it is simply dropped.
                        let trimmed = destination.trimmingCharacters(in: .whitespaces)
                        let href =
                            trimmed.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
                        return Bracketed(
                            labelStart: start + 1,
                            labelEnd: labelEnd,
                            destination: href,
                            end: index + 1
                        )
                    }
                    destination.append(character)
                    index += 1
                    continue
                }
                destination.append(character)
                index += 1
            }
            return nil
        }

        // MARK: - emphasis

        private struct Emphasis {
            var kind: MarkdownSpan.Kind
            var contentStart: Int
            var contentEnd: Int
            var end: Int
        }

        private func emphasis(at start: Int, hi: Int) -> Emphasis? {
            let character = chars[start]
            guard character == "*" || character == "_" || character == "~" else { return nil }
            let doubled = start + 1 < hi && chars[start + 1] == character
            if character == "~" && !doubled { return nil }

            let width = doubled ? 2 : 1
            let kind: MarkdownSpan.Kind
            switch (character, doubled) {
            case ("~", _): kind = .strike
            case (_, true): kind = .strong
            default: kind = .em
            }

            let contentStart = start + width
            guard contentStart < hi, !chars[contentStart].isWhitespace else { return nil }
            // `snake_case_words` must not turn into emphasis, so an underscore run may not open
            // from inside a word.
            if character == "_", start > 0, chars[start - 1].isMarkdownWordCharacter { return nil }

            var index = contentStart
            while index < hi {
                if chars[index] == "\\" {
                    index += 2
                    continue
                }
                let isRun =
                    chars[index] == character
                    && (!doubled || (index + 1 < hi && chars[index + 1] == character))
                if isRun, index > contentStart, !chars[index - 1].isWhitespace {
                    let after = index + width
                    if character == "_", after < hi, chars[after].isMarkdownWordCharacter {
                        index += 1
                        continue
                    }
                    return Emphasis(
                        kind: kind,
                        contentStart: contentStart,
                        contentEnd: index,
                        end: after
                    )
                }
                index += 1
            }
            return nil
        }
    }
}

extension Character {
    fileprivate var isMarkdownPunctuation: Bool {
        "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~".contains(self)
    }

    fileprivate var isMarkdownWordCharacter: Bool {
        isLetter || isNumber || self == "_"
    }
}
