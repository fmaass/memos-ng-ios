import Foundation

// The composer's half of a pinned trip: the trip's tag added to a new memo as a line of its own.
//
// Tags have no field anywhere — the server reads them out of the memo's words — so "does this
// memo already carry the tag" is answered with the SERVER's reading, not the timeline's. memos-ng
// (app/services/memos.py at the commit `Packages/MemosAPI/OPENAPI_SOURCE` names) takes every match
// of `#(\w+)` over the whole content: Python 3 `re` on a `str`, so `\w` is Unicode, greedy, with no
// boundary asked for before the `#`, and the tags are kept by exact, case-sensitive string. The
// display-side `isTagOnlyLine` is an ASCII port of the SPA's line hider and is deliberately not
// used here: it answers a different question.

/// Every tag the server would read out of `content`, in order, duplicates kept.
///
/// Matches are taken left to right and never overlap, as `re.findall` takes them: `#a#b` is `a`
/// then `b`, `##a` is `a`, and `x#a` is `a`. A `#` followed by no word character is not a tag.
/// The reading is done on Unicode scalars, which is what Python's `str` is made of — so a letter
/// written as a base and a combining mark ends the tag at the mark, exactly as the server ends it.
public func serverHashtags(in content: String) -> [String] {
    var tags: [String] = []
    let scalars = Array(content.unicodeScalars)
    var index = 0
    while index < scalars.count {
        guard scalars[index] == "#" else {
            index += 1
            continue
        }
        var end = index + 1
        while end < scalars.count, isServerWordScalar(scalars[end]) { end += 1 }
        if end > index + 1 {
            var tag = String.UnicodeScalarView()
            tag.append(contentsOf: scalars[(index + 1)..<end])
            tags.append(String(tag))
            index = end
        } else {
            index += 1
        }
    }
    return tags
}

/// Whether the server would read `tag` out of `content` — the exact tag, compared scalar by
/// scalar and case-sensitively, as the server's set of strings compares it.
///
/// `#Portugal2026` does not carry `portugal2026` (the server would keep both), nor does
/// `#portugal2026x` (that is a different tag), nor the bare word without its `#`. An empty tag is
/// never carried.
public func contentCarriesTag(_ content: String, tag: String) -> Bool {
    guard !tag.isEmpty else { return false }
    let wanted = Array(tag.unicodeScalars)
    return serverHashtags(in: content).contains { Array($0.unicodeScalars) == wanted }
}

/// `content` with `#<tag>` as its last line, unless the server would already read that tag out of
/// it — then `content` unchanged, so applying it twice is applying it once.
///
/// Trailing whitespace and blank lines are dropped before the line is added, so a memo that ends
/// in a newline gains exactly one line break, never a blank line. Empty (or whitespace-only)
/// content becomes `#<tag>` alone, with no line break in front of it. An empty tag changes
/// nothing.
public func appendingPinnedTag(_ tag: String, to content: String) -> String {
    guard !tag.isEmpty, !contentCarriesTag(content, tag: tag) else { return content }
    var body = content
    while let last = body.last, last.isWhitespace { body.removeLast() }
    return body.isEmpty ? "#\(tag)" : "\(body)\n#\(tag)"
}

/// Python 3's `\w` on a `str`: a letter (general category L*), anything with a numeric value, or
/// the underscore. Combining marks are not word characters there, and are not here.
private func isServerWordScalar(_ scalar: Unicode.Scalar) -> Bool {
    if scalar == "_" { return true }
    switch scalar.properties.generalCategory {
    case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter:
        return true
    default:
        return scalar.properties.numericType != nil
    }
}
