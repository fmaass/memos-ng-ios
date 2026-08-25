import Foundation

// Ported from the SPA's `frontend/src/lib/markdown.ts:24-42`, vectors included: a memo's tags
// already show as chips under it, so a line that is nothing but hashtags would read as a title if
// the body rendered it too. The two functions are separate because callers need to map rendered
// output back to source line numbers, and the renderer never sees the dropped lines.

/// A line that is ONLY hashtags (`#curated`, `#curated #trip`).
///
/// `#word` requires no space after `#`, so a real Markdown heading (`# Heading`) is preserved and
/// an inline tag in prose ("see #curated") is not a tag-only line.
///
/// A trailing carriage return is NOT whitespace here, deliberately. The SPA's regex ends in
/// `[ \t]*$`, and JavaScript's `$` matches at the end of the string only — without `/m` it does
/// not match before a line terminator — so `#curated\r` is not a tag-only line there either, and
/// a memo written with CRLF endings shows its tag line as body text in both clients. Accepting
/// `\r` here would be the tidier reading of the spec and a divergence from the SPA, which is the
/// one thing this port may not be. (MEMNG-144, pinned in `TagOnlyLinesTests`.)
public func isTagOnlyLine(_ line: String) -> Bool {
    var index = line.startIndex
    let end = line.endIndex

    func skipSpaces() {
        while index < end, line[index] == " " || line[index] == "\t" {
            index = line.index(after: index)
        }
    }

    func takeTag() -> Bool {
        guard index < end, line[index] == "#" else { return false }
        index = line.index(after: index)
        var length = 0
        while index < end, line[index].isWordCharacter {
            index = line.index(after: index)
            length += 1
        }
        return length > 0
    }

    skipSpaces()
    guard takeTag() else { return false }
    while true {
        let beforeSpaces = index
        var sawSpace = false
        while index < end, line[index] == " " || line[index] == "\t" {
            index = line.index(after: index)
            sawSpace = true
        }
        if index == end { return true }
        guard sawSpace else { return false }
        guard takeTag() else {
            index = beforeSpaces
            return false
        }
    }
}

/// Drops whole lines that consist solely of hashtags.
public func stripTagOnlyLines(_ source: String) -> String {
    source
        .components(separatedBy: "\n")
        .filter { !isTagOnlyLine($0) }
        .joined(separator: "\n")
}

extension Character {
    /// JavaScript's `\w`: ASCII letters, digits and underscore — the class the SPA's regex uses.
    /// `Character.isLetter` would also accept accented and non-Latin letters and quietly strip
    /// lines the SPA keeps.
    fileprivate var isWordCharacter: Bool {
        ("a"..."z").contains(self) || ("A"..."Z").contains(self) || ("0"..."9").contains(self)
            || self == "_"
    }
}
