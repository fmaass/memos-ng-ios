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

    /// Rewrites the LINKS in `source`, and leaves every code block exactly as it was typed.
    ///
    /// Code is a barrier here, not a special case. Both things the walk below does — escaping a
    /// link the SPA would leave as text, deleting an image the SPA drops — are visible inside a
    /// code block: one as a backslash on screen, the other as a line of the author's code silently
    /// gone. markdown-it parses no inline at all inside one, so there is no parity to trade
    /// (probed: a `~~~` fence at top level, in a quote and in a list item, a four-backtick fence
    /// and an indented block all keep `[x](javascript:alert(1))` and `![alt][pic]` character for
    /// character). Only a three-backtick fence used to survive it here, and only by accident: its
    /// backticks toggled the code-span flag an even number of times.
    ///
    /// Nothing is scanned across a block's edge either, which is why this walks RUNS of prose
    /// lines rather than the whole document: a construct that opens in a paragraph and closes
    /// inside the code block below it is not a construct, and consuming it would delete code.
    static func neutralizeUnsafeInline(
        _ source: String,
        resolvableLabels: Set<String> = []
    ) -> String {
        let lines = sourceLines(source)
        let scans = scanLines(lines)
        var out = ""
        var prose = ""

        for index in lines.indices {
            let line = lines[index]
            guard scans[index].isCode else {
                prose += line.raw + line.ending
                continue
            }
            out += neutralizeUnsafeInline(inProse: prose, resolvableLabels: resolvableLabels)
            prose = ""
            out += line.raw + line.ending
        }
        return out + neutralizeUnsafeInline(inProse: prose, resolvableLabels: resolvableLabels)
    }

    /// The character walk itself, over one run of lines that are not code. A code SPAN may cross
    /// the newlines inside such a run — which is why this is not per-line — and cannot cross a
    /// code block, which is why the run ends at one.
    private static func neutralizeUnsafeInline(
        inProse source: String,
        resolvableLabels: Set<String>
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
        /// The source with every unsafe definition line neutralised, byte for byte otherwise.
        var source: String
        /// Labels that still resolve after that, normalised the way CommonMark matches them.
        var labels: Set<String>
    }

    /// Escapes the opening bracket of every `[label]: destination` line whose destination would
    /// not survive the SPA's sanitiser, which is what markdown-it's refusal to register such a
    /// definition looks like from the outside: the line stops being a definition and stays on
    /// screen as text, and every reference that named the label becomes literal text as well.
    ///
    /// Everything this needs to know about a line — where it ends, which containers it is inside,
    /// how far its content is indented — is decided ONCE, by `sourceLines`, and what the line IS
    /// is decided once by `scanLines`. Four review rounds found four spellings that a per-site
    /// reading of the raw line got wrong (a tab after a list marker, a lone-CR line ending,
    /// indented code inside a blockquote, a marker-only list item); they are not four patches but
    /// one layer, because the class is "this scanner's idea of block structure differs from
    /// cmark's" and only a shared layer can be held to the spec in one place. This function is
    /// then only the two decisions that are ITS own: which label may resolve, and which line's
    /// bracket is escaped.
    ///
    /// Being too eager costs nothing — escaping a `[` in a line that was prose all along renders
    /// exactly as it did before, `\[` is a literal `[` — while being too clever costs a live
    /// `javascript:` link. Registering a label is the opposite bet, because a label wrongly
    /// thought to be defined deletes a `![text]` a reader was meant to see, so that happens only
    /// where a definition can actually begin.
    static func neutralizeUnsafeReferenceDefinitions(_ source: String) -> ReferenceScan {
        var lines = sourceLines(source)
        let scans = scanLines(lines)
        var labels: Set<String> = []

        for index in lines.indices {
            guard let definition = scans[index].definition,
                let href = scans[index].destination, !href.isEmpty
            else { continue }

            if scans[index].registers {
                labels.insert(normalizedLabel(definition.label))
            } else if !MarkdownInline.isTappableScheme(href) {
                var characters = Array(lines[index].raw)
                characters.insert("\\", at: lines[index].contentOffset + definition.bracketOffset)
                lines[index].raw = String(characters)
            }
        }
        return ReferenceScan(
            source: lines.map { $0.raw + $0.ending }.joined(),
            labels: labels
        )
    }

    /// What each line of the document IS, decided once for both passes.
    private struct LineScan {
        /// Fenced code — its opening and closing markers included — or an indented code block.
        /// The author's characters, which neither pass may rewrite.
        var isCode = false
        /// A `[label]: destination` line, wherever one is written. It is a DEFINITION only when
        /// `registers` says so.
        var definition: DefinitionLine?
        /// The destination that definition would have, the next-line spelling included.
        var destination: String?
        /// The line is a definition that CommonMark registers AND whose destination survives the
        /// SPA's sanitiser — the only case where a label may resolve.
        var registers = false
    }

    /// Reads the document once: which lines are code, which are definitions, and which of those
    /// register a label.
    ///
    /// The three questions share one answer — whether a new block may begin on this line — so
    /// they share one pass. Asking them separately is how a scanner ends up believing a line is
    /// a definition and a code block at the same time.
    ///
    /// The rules it holds, each one probed against markdown-it rather than assumed:
    ///
    /// - a definition markdown-it REFUSES is not a definition. `rules_block/reference.js` returns
    ///   false when `validateLink` rejects the destination, the paragraph rule takes the line
    ///   instead, and a definition cannot interrupt a paragraph — so nothing below it registers
    ///   until that paragraph ends. The same holds for a definition-shaped line that follows
    ///   prose: it is paragraph text, and so is the next one;
    /// - an indented code block cannot interrupt a paragraph either, so `paragraph` then four
    ///   spaces is a lazy continuation, while the same four spaces after a heading, a thematic
    ///   break, a registered definition, a closed fence or a blank line are code;
    /// - a blank line inside an indented code block does not end it, but a marker-only line is not
    ///   blank: it is a container whose content begins on the next line.
    private static func scanLines(_ lines: [SourceLine]) -> [LineScan] {
        var scans = [LineScan](repeating: LineScan(), count: lines.count)
        var fence: (character: Character, length: Int, depth: Int)?
        var atBlockStart = true
        var inIndentedCode = false

        for index in lines.indices {
            let line = lines[index]

            if let open = fence {
                if line.depth < open.depth, line.indentColumns == 0 {
                    // The container that held the fence has ended. A fence inside a blockquote
                    // cannot swallow the rest of the document — and a scanner that lets it stops
                    // looking at every definition below.
                    //
                    // Only an UNINDENTED line ends it, though: the continuation lines of a list
                    // item carry no marker of their own, so their depth reads as zero while they
                    // are still inside the item. Closing on those turns the code inside a fenced
                    // block into a definition and deletes the `![alt][ref]` below it.
                    fence = nil
                    atBlockStart = true
                } else {
                    scans[index].isCode = true
                    if let closing = fenceMarker(line), closing.character == open.character,
                        closing.length >= open.length, closing.info.isEmpty
                    {
                        fence = nil
                    }
                    // A fenced block is a leaf block: what follows it begins a block of its own.
                    atBlockStart = true
                    continue
                }
            }
            if let opening = fenceMarker(line) {
                fence = (opening.character, opening.length, line.depth)
                scans[index].isCode = true
                inIndentedCode = false
                atBlockStart = true
                continue
            }
            if line.content.trimmingCharacters(in: .whitespaces).isEmpty, !line.isMarkerOnly {
                // A blank line ends a block and holds nothing to protect — and it does not end an
                // indented code block, which runs on across it.
                atBlockStart = true
                continue
            }
            if line.isIndentedCode, inIndentedCode || atBlockStart {
                inIndentedCode = true
                scans[index].isCode = true
                atBlockStart = true
                continue
            }
            inIndentedCode = false

            guard let definition = definitionLine(line) else {
                if line.isMarkerOnly, !atBlockStart {
                    // An empty list item cannot interrupt a paragraph, and neither can an ordered
                    // marker whose number is not 1. A lone `2.` in the middle of one is text, the
                    // line after it is text, and nothing there is a definition.
                    atBlockStart = false
                } else {
                    // A blank line ends a block, and so does a line that was nothing but container
                    // markers, and so does a heading or a thematic break.
                    atBlockStart = endsABlock(line.content)
                }
                continue
            }

            var destination = definition.destination
            if destination == nil, index + 1 < lines.count {
                // CommonMark lets the destination sit on the line after the label. cmark-gfm
                // registers that spelling; markdown-it validates it the same as any other.
                //
                // Only while that line is still in the same block, though — which is a question
                // about the line BEFORE its markers come off. `- https://…` opens a list item, so
                // it is not the destination of the `[pic]:` above it, and reading it as one
                // registers a label the document never defined.
                let next = lines[index + 1]
                if next.depth <= line.depth {
                    destination = firstToken(of: next.content)
                }
            }
            scans[index].definition = definition
            scans[index].destination = destination

            let survives = destination.map(MarkdownInline.isTappableScheme) ?? false
            scans[index].registers = atBlockStart && survives
            // One definition may follow another; a definition never opens a paragraph — but a
            // line that was NOT one leaves the paragraph it belongs to open underneath it.
            atBlockStart = scans[index].registers && definition.destination != nil
        }
        return scans
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

    // MARK: The one layer everything above reads

    /// A source line as the scanner needs to see it.
    ///
    /// `raw` and `ending` put the document back together byte for byte; `content` is what is left
    /// once the containers this line sits in have been peeled off, which is the only thing whose
    /// indentation, fence-ness and definition-ness mean anything.
    struct SourceLine {
        /// The line as the author wrote it, its ending excluded.
        var raw: String
        /// The ending that followed it: `\n`, `\r\n`, `\r`, or nothing at the end of the source.
        var ending: String
        /// What is left after the blockquote and list markers, its own indentation included.
        var content: String
        /// Where `content` begins inside `raw`, counted in Characters.
        var contentOffset: Int
        /// How many containers were peeled off. A fence opened inside one cannot swallow lines
        /// that sit outside it.
        var depth: Int
        /// Columns of indentation in front of the content, tabs advancing to 4-column tab stops.
        var indentColumns: Int

        /// Four columns of indent with something after them: an indented code block. No
        /// definition can sit inside one, and the first line that is not indented ends it.
        var isIndentedCode: Bool {
            indentColumns >= 4 && !content.trimmingCharacters(in: .whitespaces).isEmpty
        }

        /// Nothing but container markers: an empty list item, or an empty quote line. It opens a
        /// block of its own only where it is allowed to interrupt what is already open.
        var isMarkerOnly: Bool {
            depth > 0 && content.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    /// Splits the source the way CommonMark splits it — `\n`, `\r\n` and a lone `\r` are all line
    /// endings — and peels the container markers off each line.
    ///
    /// A memo written on a device that ends its lines with `\r` alone is the same memo, and cmark
    /// reads it as one. A scanner that only knows `\n` sees a single enormous line and looks at
    /// none of it.
    static func sourceLines(_ source: String) -> [SourceLine] {
        // Scalars, not Characters. Swift reads `\r\n` as ONE extended grapheme cluster, so a
        // Character-by-Character walk of a CRLF memo never matches `\n` or `\r` and hands the
        // scanner a single enormous line — the very failure this layer exists to make impossible.
        let scalars = Array(source.unicodeScalars)
        var lines: [SourceLine] = []
        var raw = String.UnicodeScalarView()
        var index = 0

        while index < scalars.count {
            let scalar = scalars[index]
            guard scalar == "\n" || scalar == "\r" else {
                raw.append(scalar)
                index += 1
                continue
            }
            var ending = String(scalar)
            index += 1
            if scalar == "\r", index < scalars.count, scalars[index] == "\n" {
                ending.append("\n")
                index += 1
            }
            lines.append(makeLine(raw: String(raw), ending: ending))
            raw = String.UnicodeScalarView()
        }
        lines.append(makeLine(raw: String(raw), ending: ""))
        return lines
    }

    /// Peels blockquote and list markers off, one after another, the way a document nests them.
    /// Whitespace runs are measured in COLUMNS with four-column tab stops, because that is what
    /// decides whether what follows is indented code or the content of the container.
    private static func makeLine(raw: String, ending: String) -> SourceLine {
        let chars = Array(raw)
        var index = 0
        var depth = 0
        var indentStart = 0

        while index < chars.count {
            if chars[index] == " " || chars[index] == "\t" {
                index += 1
                continue
            }
            // Four columns of indentation is an indented code block, not room before a marker.
            if columnWidth(chars, from: indentStart, to: index) >= 4 { break }
            if chars[index] == ">" {
                index += 1
                depth += 1
                // The marker may be followed by one space, which belongs to the marker.
                if index < chars.count, chars[index] == " " || chars[index] == "\t" { index += 1 }
                indentStart = index
                continue
            }
            if let marker = listMarkerWidth(chars, at: index) {
                index += marker
                depth += 1
                indentStart = index
                continue
            }
            break
        }

        var contentEnd = indentStart
        while contentEnd < chars.count, chars[contentEnd] == " " || chars[contentEnd] == "\t" {
            contentEnd += 1
        }
        return SourceLine(
            raw: raw,
            ending: ending,
            content: String(chars[indentStart...]),
            contentOffset: indentStart,
            depth: depth,
            indentColumns: columnWidth(chars, from: indentStart, to: contentEnd)
        )
    }

    /// The width of a whitespace run in columns: a tab advances to the next four-column tab stop,
    /// which is how CommonMark measures indentation and list-marker padding.
    private static func columnWidth(_ chars: [Character], from start: Int, to end: Int) -> Int {
        var columns = 0
        var index = start
        while index < end, index < chars.count {
            if chars[index] == "\t" {
                columns += 4 - (columns % 4)
            } else {
                columns += 1
            }
            index += 1
        }
        return columns
    }

    /// How wide the list marker starting here is, the one whitespace character that belongs to it
    /// included: `- `, `*\t`, `+ `, `1. `, `12) `, or a marker alone at the end of its line — an
    /// item whose content starts on the NEXT line is still an item. `nil` when this is not a
    /// marker: `-[x]` opens no list.
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
        guard index < chars.count else { return index - start }
        guard chars[index] == " " || chars[index] == "\t" else { return nil }
        return index + 1 - start
    }

    /// True when nothing on this line can be continued by the next one, so the next line begins a
    /// block of its own. A definition cannot interrupt a paragraph, which is what this rules out.
    private static func endsABlock(_ content: String) -> Bool {
        let body = content.trimmingCharacters(in: .whitespaces)
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

    private struct DefinitionLine {
        var label: String
        /// `nil` when the label was followed by nothing — the destination is on the next line.
        var destination: String?
        /// Where the `[` sits inside the line's CONTENT, so the escape lands in front of it.
        var bracketOffset: Int
    }

    private static func definitionLine(_ line: SourceLine) -> DefinitionLine? {
        // Inside an indented code block there are no definitions, only code.
        guard line.indentColumns < 4 else { return nil }
        let chars = Array(line.content)
        var index = 0
        while index < chars.count, chars[index] == " " || chars[index] == "\t" { index += 1 }

        let bracketOffset = index
        guard let label = scanBracketed(chars, at: index) else { return nil }
        guard !label.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        index = label.end
        guard index < chars.count, chars[index] == ":" else { return nil }
        index += 1
        while index < chars.count, chars[index] == " " || chars[index] == "\t" { index += 1 }

        return DefinitionLine(
            label: label.text,
            destination: destinationToken(String(chars[index...])),
            bracketOffset: bracketOffset
        )
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

    private static func firstToken(of content: String) -> String? {
        destinationToken(content)
    }

    private static func fenceMarker(
        _ line: SourceLine
    ) -> (character: Character, length: Int, info: String)? {
        guard line.indentColumns < 4 else { return nil }
        let chars = Array(line.content)
        var index = 0
        while index < chars.count, chars[index] == " " || chars[index] == "\t" { index += 1 }
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
