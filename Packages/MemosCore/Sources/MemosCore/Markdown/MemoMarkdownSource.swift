import Foundation

/// Prepares memo content for the renderer.
///
/// Security-critical and therefore a pure function with its own tests rather than something a view
/// does inline. Three things the SPA's pipeline does that a general-purpose Markdown renderer will
/// not do on its own:
///
/// - a link whose scheme is not `http`, `https` or `mailto` must render as the plain characters
///   the author typed, never as something tappable;
/// - the same has to hold for the REFERENCE form of a link. markdown-it validates a link
///   reference definition where it is DEFINED (`rules_block/reference.js` runs `validateLink`
///   before registering the label), so a `[evil]: javascript:…` line is never registered, the
///   definition stays on screen as text and every `[click][evil]` that names it falls back to
///   text too. cmark-gfm — the parser behind MarkdownUI — has no such check: it resolves the
///   reference and hands the view a live `javascript:` destination, which
///   `AttributedStringInlineRenderer` turns straight into `attributes.link`. Neutralising only the
///   inline form therefore leaves the scheme rule bypassable by writing the same link in
///   reference syntax;
/// - an image is dropped whole — `img` is not in the sanitiser's allowlist, and a removed void
///   element takes its alt text with it. That applies to `![alt][ref]` as much as to
///   `![alt](url)`, or a reference image would be the same hole again, this time fetching a
///   remote URL the SPA never requests.
///
/// The scheme test is DOMPurify's allowlist (`isTappableScheme`), the same one the inline form
/// uses, so both spellings of a link answer to one rule. It is stricter than markdown-it's
/// `validateLink`: a destination markdown-it builds a link from but DOMPurify then strips the
/// `href` off (`ftp:`, a relative path) renders in the SPA as the label text alone, and here as
/// the literal characters the author typed. That difference is pre-existing, deliberate and the
/// same for both spellings — safety is decided by one predicate, not by which syntax was used.
public enum MemoMarkdownSource {
    public static func prepare(_ content: String) -> String {
        let references = neutralizeUnsafeReferenceDefinitions(stripTagOnlyLines(content))
        return neutralizeUnsafeInline(references.source, resolvableLabels: references.labels)
    }

    static func neutralizeUnsafeInline(
        _ source: String,
        resolvableLabels: Set<String> = []
    ) -> String {
        let chars = Array(source)
        var out = ""
        var index = 0
        var inCodeSpan = false

        while index < chars.count {
            let character = chars[index]

            if character == "\\", index + 1 < chars.count {
                out.append(character)
                out.append(chars[index + 1])
                index += 2
                continue
            }
            if character == "`" {
                inCodeSpan.toggle()
                out.append(character)
                index += 1
                continue
            }
            if inCodeSpan {
                out.append(character)
                index += 1
                continue
            }
            if character == "!", index + 1 < chars.count, chars[index + 1] == "[",
                let link = scanLink(chars, at: index + 1, resolvableLabels: resolvableLabels)
            {
                // Inline or reference: an image leaves nothing behind either way.
                index = link.end
                continue
            }
            if character == "[",
                let link = scanLink(chars, at: index, resolvableLabels: resolvableLabels),
                case .inline(let destination) = link.kind
            {
                if MarkdownInline.isTappableScheme(destination) {
                    out += String(chars[index..<link.end])
                } else {
                    // Escaping the opening bracket is what leaves the whole construct on screen as
                    // text, which is exactly what the SPA shows.
                    out += "\\" + String(chars[index..<link.end])
                }
                index = link.end
                continue
            }
            out.append(character)
            index += 1
        }
        return out
    }

    private enum LinkKind {
        case inline(destination: String)
        /// `[text][label]`, `[text][]` or a bare `[label]` — but only when the label resolves
        /// to a definition that survived `neutralizeUnsafeReferenceDefinitions`, because an
        /// unresolved label is literal text in cmark-gfm and in markdown-it alike, and must be
        /// left alone.
        case reference
    }

    private struct ScannedLink {
        var kind: LinkKind
        var end: Int
    }

    /// Reads the link construct that starts at `chars[start] == "["`, in any of the four
    /// spellings CommonMark gives it. A construct whose reference cannot be resolved is not a
    /// link at all, and is reported as such (`nil`) so the caller leaves the characters alone.
    private static func scanLink(
        _ chars: [Character],
        at start: Int,
        resolvableLabels: Set<String>
    ) -> ScannedLink? {
        guard let label = scanBracketed(chars, at: start) else { return nil }
        let afterLabel = label.end

        if afterLabel < chars.count, chars[afterLabel] == "(" {
            guard let destination = scanInlineDestination(chars, at: afterLabel) else { return nil }
            return ScannedLink(
                kind: .inline(destination: destination.href),
                end: destination.end
            )
        }
        if afterLabel < chars.count, chars[afterLabel] == "[" {
            guard let reference = scanBracketed(chars, at: afterLabel) else { return nil }
            // `[text][]` is the collapsed form: the label IS the text.
            let inner = reference.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = inner.isEmpty ? label.text : reference.text
            guard resolvableLabels.contains(normalizedLabel(name)) else { return nil }
            return ScannedLink(kind: .reference, end: reference.end)
        }
        // The shortcut form: a bare `[label]` is a link only when that label is defined.
        guard resolvableLabels.contains(normalizedLabel(label.text)) else { return nil }
        return ScannedLink(kind: .reference, end: afterLabel)
    }

    private struct Bracketed {
        var text: String
        /// The index just past the closing `]`.
        var end: Int
    }

    private static func scanBracketed(_ chars: [Character], at start: Int) -> Bracketed? {
        guard start < chars.count, chars[start] == "[" else { return nil }
        var depth = 0
        var index = start
        var text = ""
        while index < chars.count {
            let character = chars[index]
            if character == "\\", index + 1 < chars.count {
                if depth > 0 {
                    text.append(character)
                    text.append(chars[index + 1])
                }
                index += 2
                continue
            }
            if character == "[" {
                depth += 1
                if depth > 1 { text.append(character) }
                index += 1
                continue
            }
            if character == "]" {
                depth -= 1
                if depth == 0 { return Bracketed(text: text, end: index + 1) }
                text.append(character)
                index += 1
                continue
            }
            if depth > 0 { text.append(character) }
            index += 1
        }
        return nil
    }

    private struct InlineDestination {
        var href: String
        /// The index just past the closing `)`.
        var end: Int
    }

    private static func scanInlineDestination(
        _ chars: [Character],
        at start: Int
    ) -> InlineDestination? {
        var parenDepth = 0
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
                parenDepth += 1
                if parenDepth > 1 { destination.append(character) }
                index += 1
                continue
            }
            if character == ")" {
                parenDepth -= 1
                if parenDepth == 0 {
                    let trimmed = destination.trimmingCharacters(in: .whitespaces)
                    let href =
                        trimmed.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
                    return InlineDestination(href: href, end: index + 1)
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
}

// MARK: - Link reference definitions

extension MemoMarkdownSource {
    struct ReferenceScan {
        /// The source with every unsafe definition line neutralised.
        var source: String
        /// Labels that still resolve after that, normalised the way CommonMark matches them.
        var labels: Set<String>
    }

    /// Escapes the opening bracket of every `[label]: destination` line whose destination would
    /// not survive the SPA's sanitiser, which is what markdown-it's refusal to register such a
    /// definition looks like from the outside: the line stops being a definition and stays on
    /// screen as text, and every reference that named the label becomes literal text as well,
    /// because neither parser resolves a label it has no definition for.
    ///
    /// Neutralising is applied to any line SHAPED like a definition outside a fenced code block,
    /// not only to the ones a full parse would accept: escaping a `[` in a line that was ordinary
    /// prose all along renders exactly as it did before (`\[` is a literal `[`), so the cost of
    /// being too eager is nothing, while the cost of being too clever is a live `javascript:`
    /// link in whichever position the line-position rules were not modelled faithfully.
    ///
    /// Collecting the labels that DO resolve is the opposite bet, because a label wrongly thought
    /// to be defined makes the image rule delete `![text]` a reader was meant to see. So a label
    /// is registered only from a line that starts a block, which is the only place a definition
    /// can be.
    static func neutralizeUnsafeReferenceDefinitions(_ source: String) -> ReferenceScan {
        var lines = source.components(separatedBy: "\n")
        var labels: Set<String> = []
        var fence: (character: Character, length: Int)?
        var atBlockStart = true

        for index in lines.indices {
            let line = lines[index]
            // A memo written on a device that ends its lines with CRLF is the same memo, and
            // cmark normalises the endings before it parses. So every line-shaped question here
            // is asked of the line WITHOUT its carriage return — a `\r` left on a closing fence
            // makes the fence never close, and everything below it stops being looked at. The
            // escape is still inserted into the line as the author wrote it.
            let body = withoutCarriageReturn(line)
            let openedThisBlock = atBlockStart
            if let open = fence {
                if let closing = fenceMarker(body), closing.character == open.character,
                    closing.length >= open.length, closing.info.isEmpty
                {
                    fence = nil
                    atBlockStart = true
                }
                continue
            }
            if let opening = fenceMarker(body) {
                fence = (opening.character, opening.length)
                atBlockStart = false
                continue
            }
            guard let definition = definitionLine(body) else {
                // A blank line is not the only thing that ends a block: an indented code block
                // ends at the first line that is not indented, and a definition may sit on that
                // line. Missing it leaves the label unregistered, and an unregistered label is a
                // reference image this code will not drop.
                atBlockStart = endsABlock(body) || (openedThisBlock && isIndentedCode(body))
                continue
            }

            var destination = definition.destination
            if destination == nil, index + 1 < lines.count {
                // CommonMark lets the destination sit on the line after the label. cmark-gfm
                // registers that spelling; markdown-it validates it the same as any other.
                destination = firstToken(of: withoutCarriageReturn(lines[index + 1]))
            }
            guard let href = destination, !href.isEmpty else {
                atBlockStart = false
                continue
            }

            if MarkdownInline.isTappableScheme(href) {
                if atBlockStart { labels.insert(normalizedLabel(definition.label)) }
            } else {
                var characters = Array(line)
                characters.insert("\\", at: definition.bracketOffset)
                lines[index] = String(characters)
            }
            // One definition may follow another; a definition never opens a paragraph.
            atBlockStart = definition.destination != nil
        }
        return ReferenceScan(source: lines.joined(separator: "\n"), labels: labels)
    }

    private static func withoutCarriageReturn(_ line: String) -> String {
        line.hasSuffix("\r") ? String(line.dropLast()) : line
    }

    /// Four columns of indent with something after them: an indented code block. No definition
    /// can sit inside one, and the first line that is not indented ends it.
    private static func isIndentedCode(_ line: String) -> Bool {
        var columns = 0
        for character in line {
            if character == " " {
                columns += 1
                continue
            }
            if character == "\t" {
                columns += 4
                continue
            }
            return columns >= 4
        }
        return false
    }

    /// True when nothing on this line can be continued by the next one, so the next line begins a
    /// block of its own. A definition cannot interrupt a paragraph, which is what this rules out.
    private static func endsABlock(_ line: String) -> Bool {
        let body = line.trimmingCharacters(in: .whitespaces)
        if body.isEmpty { return true }
        if body.hasPrefix("#") {
            let hashes = body.prefix { $0 == "#" }
            if hashes.count <= 6, body.dropFirst(hashes.count).first.map(\.isWhitespace) ?? true {
                return true
            }
        }
        if body.count >= 3, let first = body.first, "-*_".contains(first),
            body.allSatisfy({ $0 == first })
        {
            return true
        }
        return false
    }

    /// CommonMark matches reference labels case-insensitively and treats any run of whitespace
    /// inside one as a single space.
    static func normalizedLabel(_ label: String) -> String {
        var out = ""
        var pendingSpace = false
        for character in label {
            if character.isWhitespace {
                pendingSpace = !out.isEmpty
                continue
            }
            if pendingSpace {
                out.append(" ")
                pendingSpace = false
            }
            out.append(character)
        }
        return out.lowercased()
    }

    private struct DefinitionLine {
        var label: String
        /// `nil` when the label was followed by nothing — the destination is on the next line.
        var destination: String?
        /// Where the `[` sits in the line, so the escape lands in front of it.
        var bracketOffset: Int
    }

    private static func definitionLine(_ line: String) -> DefinitionLine? {
        let chars = Array(line)
        var index = 0
        var indent = 0
        // Blockquote markers may precede the definition, and each level restarts the indent that
        // would otherwise make the line an indented code block.
        while index < chars.count {
            if chars[index] == " " {
                indent += 1
                if indent > 3 { return nil }
                index += 1
                continue
            }
            if chars[index] == "\t" { return nil }
            if chars[index] == ">" {
                index += 1
                indent = 0
                if index < chars.count, chars[index] == " " { index += 1 }
                continue
            }
            // A list marker opens a block a definition may sit in, and CommonMark registers a
            // definition written inside a list item for the WHOLE document — so
            // `- [evil]: javascript:…` is a definition, and a prefix scanner that knows `>` but
            // not `-` is one bullet away from letting the scheme rule be bypassed.
            if let marker = listMarkerWidth(chars, at: index) {
                index += marker
                indent = 0
                continue
            }
            break
        }
        let bracketOffset = index
        guard let label = scanBracketed(chars, at: index) else { return nil }
        guard !label.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        index = label.end
        guard index < chars.count, chars[index] == ":" else { return nil }
        index += 1
        while index < chars.count, chars[index] == " " || chars[index] == "\t" { index += 1 }

        let rest = String(chars[index...])
        return DefinitionLine(
            label: label.text,
            destination: destinationToken(rest),
            bracketOffset: bracketOffset
        )
    }

    /// How wide the list marker starting here is, the space that must follow it included:
    /// `- `, `* `, `+ `, `1. `, `12) `. `nil` when this is not one — `-[x]` opens no list item.
    private static func listMarkerWidth(_ chars: [Character], at start: Int) -> Int? {
        var index = start
        if chars[index] == "-" || chars[index] == "+" || chars[index] == "*" {
            index += 1
        } else {
            var digits = 0
            while index < chars.count, ("0"..."9").contains(chars[index]), digits < 9 {
                index += 1
                digits += 1
            }
            guard digits > 0, index < chars.count, chars[index] == "." || chars[index] == ")"
            else { return nil }
            index += 1
        }
        guard index < chars.count, chars[index] == " " else { return nil }
        return index + 1 - start
    }

    /// The destination as CommonMark reads it: either `<…>` or an unbroken run of characters.
    /// `nil` for an empty rest, which is the spelling that continues on the next line.
    private static func destinationToken(_ rest: String) -> String? {
        let trimmed = rest.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("<"), let close = trimmed.dropFirst().firstIndex(of: ">") {
            return String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
        }
        return trimmed.split(separator: " ", maxSplits: 1).first.map(String.init)
    }

    private static func firstToken(of line: String) -> String? {
        var body = line
        while body.hasPrefix(">") || body.hasPrefix(" ") {
            body.removeFirst()
        }
        return destinationToken(body)
    }

    private static func fenceMarker(
        _ line: String
    ) -> (character: Character, length: Int, info: String)? {
        let chars = Array(line)
        var index = 0
        while index < chars.count, chars[index] == " ", index < 3 { index += 1 }
        guard index < chars.count, chars[index] == "`" || chars[index] == "~" else { return nil }
        let character = chars[index]
        var length = 0
        while index < chars.count, chars[index] == character {
            length += 1
            index += 1
        }
        guard length >= 3 else { return nil }
        let info = String(chars[index...]).trimmingCharacters(in: .whitespaces)
        return (character, length, info)
    }
}
