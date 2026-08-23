import Foundation

/// Turns bare URLs and e-mail addresses in plain text into links, the way the SPA's `linkify`
/// option does.
///
/// Deliberately narrower than markdown-it's linkify-it: only `http(s)://…` and e-mail addresses
/// are recognised, not bare host names like `example.com`, because guessing at a TLD table is how
/// a renderer starts linking text the SPA leaves alone. A case that needs more belongs in the
/// parity fixture first.
enum Linkify {
    struct Result {
        var raw: String
        var links: [MarkdownLink]
    }

    private static let trailingPunctuation: Set<Character> = [
        ".", ",", ";", ":", "!", "?", "'", "\"", ")", "]", "}", "*", "_", "~",
    ]

    static func scan(_ text: String) -> Result {
        let chars = Array(text)
        var raw = ""
        var links: [MarkdownLink] = []
        var index = 0

        while index < chars.count {
            if let match = urlMatch(chars, at: index) {
                raw += match.text
                links.append(MarkdownLink(href: match.href, text: match.text))
                index = match.end
                continue
            }
            if let match = emailMatch(chars, at: index) {
                raw += match.text
                links.append(MarkdownLink(href: match.href, text: match.text))
                index = match.end
                continue
            }
            raw.append(chars[index])
            index += 1
        }
        return Result(raw: raw, links: links)
    }

    private struct Match {
        var text: String
        var href: String
        var end: Int
    }

    private static func urlMatch(_ chars: [Character], at start: Int) -> Match? {
        guard start == 0 || !chars[start - 1].isLinkBody else { return nil }
        let schemes = ["https://", "http://"]
        guard
            let scheme = schemes.first(where: { candidate in
                start + candidate.count <= chars.count
                    && String(chars[start..<(start + candidate.count)]).lowercased() == candidate
            })
        else { return nil }

        var end = start + scheme.count
        while end < chars.count, !chars[end].isWhitespace, chars[end] != "<", chars[end] != ">" {
            end += 1
        }
        end = trimTrailing(chars, from: start, to: end)
        guard end > start + scheme.count else { return nil }
        let text = String(chars[start..<end])
        return Match(text: text, href: text, end: end)
    }

    private static func emailMatch(_ chars: [Character], at start: Int) -> Match? {
        guard start == 0 || !chars[start - 1].isLinkBody else { return nil }
        var index = start
        while index < chars.count, chars[index].isEmailLocal { index += 1 }
        guard index > start, index < chars.count, chars[index] == "@" else { return nil }
        let atIndex = index
        index += 1
        var domainEnd = index
        while domainEnd < chars.count, chars[domainEnd].isEmailDomain { domainEnd += 1 }
        domainEnd = trimTrailing(chars, from: atIndex + 1, to: domainEnd)
        let domain = String(chars[(atIndex + 1)..<domainEnd])
        guard let dot = domain.lastIndex(of: "."),
            domain.distance(from: dot, to: domain.endIndex) > 2
        else { return nil }
        let text = String(chars[start..<domainEnd])
        return Match(text: text, href: "mailto:\(text)", end: domainEnd)
    }

    /// Sentence punctuation that happens to follow a URL is not part of it.
    private static func trimTrailing(_ chars: [Character], from start: Int, to end: Int) -> Int {
        var cursor = end
        while cursor > start, trailingPunctuation.contains(chars[cursor - 1]) {
            if chars[cursor - 1] == ")" {
                let slice = chars[start..<cursor]
                let opens = slice.filter { $0 == "(" }.count
                let closes = slice.filter { $0 == ")" }.count
                if closes <= opens { break }
            }
            cursor -= 1
        }
        return cursor
    }
}

extension Character {
    fileprivate var isLinkBody: Bool {
        isLetter || isNumber || ".-_/@".contains(self)
    }

    fileprivate var isEmailLocal: Bool {
        isLetter || isNumber || ".!#$%&'*+/=?^_`{|}~-".contains(self)
    }

    fileprivate var isEmailDomain: Bool {
        isLetter || isNumber || self == "." || self == "-"
    }
}
