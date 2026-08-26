import Foundation

/// Turns bare URLs, e-mail addresses and bare host names in plain text into links, the way the
/// SPA's `linkify` option does.
///
/// The SPA runs markdown-it with `linkify: true`, which is linkify-it with its DEFAULT settings —
/// `fuzzyLink` on and the stock TLD table. A bare `example.com` is therefore a link there
/// (`http://example.com`, the scheme linkify-it prepends), and the parity fixture pins it
/// (`linkify-bare-domain`, MEMNG-144). Recognising a host name means owning a TLD table, which is
/// why the table below is linkify-it's own rather than a guess: a renderer that invents its own
/// starts linking text the SPA leaves alone.
///
/// What is deliberately NOT modelled is the rest of linkify-it — IP literals, ports,
/// internationalised domains, `//host` — because each of those would be a link the fixture has
/// never seen. A case that needs more belongs in the parity fixture first.
enum Linkify {
    struct Result {
        var raw: String
        var links: [MarkdownLink]
    }

    /// What a match was recognised AS. The source layer needs to tell them apart: cmark-gfm's
    /// autolink extension already makes a link out of a URL and an e-mail address, so those are
    /// left character for character, while a bare host name is one only after being rewritten.
    enum Kind {
        case url
        case email
        case bareDomain
    }

    struct Match {
        var text: String
        var href: String
        var end: Int
        var kind: Kind
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
            if let match = match(chars, at: index) {
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

    /// The link that starts at `chars[start]`, if one does. Ordered the way linkify-it orders its
    /// own rules: an explicit scheme first, then an e-mail address, and a bare host name last —
    /// `memo@example.com` is one address, not a name with a host stuck to it.
    static func match(_ chars: [Character], at start: Int) -> Match? {
        urlMatch(chars, at: start)
            ?? emailMatch(chars, at: start)
            ?? bareDomainMatch(chars, at: start)
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
        return Match(text: text, href: text, end: end, kind: .url)
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
        return Match(text: text, href: "mailto:\(text)", end: domainEnd, kind: .email)
    }

    /// `example.com`, `example.com/docs?a=1` — a host whose last label is a TLD linkify-it knows,
    /// with whatever path follows it. linkify-it prepends `http://` to build the destination, and
    /// that is the href the fixture pins, so `MemoRenderPolicy` still sees a scheme it allows.
    private static func bareDomainMatch(_ chars: [Character], at start: Int) -> Match? {
        guard start == 0 || !chars[start - 1].isLinkBodyOrScheme else { return nil }
        guard let host = hostEnd(chars, at: start) else { return nil }

        var end = host
        while end < chars.count, !chars[end].isWhitespace, chars[end] != "<", chars[end] != ">" {
            end += 1
        }
        end = trimTrailing(chars, from: host, to: end)
        let text = String(chars[start..<end])
        return Match(text: text, href: "http://\(text)", end: end, kind: .bareDomain)
    }

    /// The index just past a host name of two or more labels whose last label is a known TLD, or
    /// `nil` when what starts here is not one.
    private static func hostEnd(_ chars: [Character], at start: Int) -> Int? {
        var labels: [(start: Int, end: Int)] = []
        var index = start

        while index < chars.count {
            let labelStart = index
            while index < chars.count, chars[index].isHostLabel { index += 1 }
            guard index > labelStart, chars[index - 1] != "-", chars[labelStart] != "-" else {
                return nil
            }
            labels.append((labelStart, index))
            guard index < chars.count, chars[index] == "." else { break }
            index += 1
            // A trailing dot ends the sentence, not a label: `example.com.` is `example.com`.
            guard index < chars.count, chars[index].isHostLabel else {
                index -= 1
                break
            }
        }

        guard labels.count >= 2, let last = labels.last else { return nil }
        guard isKnownTLD(String(chars[last.start..<last.end])) else { return nil }
        return last.end
    }

    /// linkify-it's stock TLD table: the generic list it ships plus every two-character ccTLD its
    /// `tlds_2ch_src_re` alternation names. Copied from linkify-it 5.x (the version markdown-it
    /// 14.2 resolves), not invented here.
    private static func isKnownTLD(_ label: String) -> Bool {
        let lowered = label.lowercased()
        if genericTLDs.contains(lowered) { return true }
        guard lowered.count == 2 else { return false }
        var characters = Array(lowered)
        guard let seconds = ccTLDSeconds[characters.removeFirst()] else { return false }
        return seconds.contains(characters[0])
    }

    private static let genericTLDs: Set<String> = [
        "biz", "com", "edu", "gov", "net", "org", "pro", "web", "xxx",
        "aero", "asia", "coop", "info", "museum", "name", "shop", "рф",
    ]

    private static let ccTLDSeconds: [Character: Set<Character>] = [
        "a": Set("cdefgilmnoqrstuwxz"),
        "b": Set("abdefghijmnorstvwyz"),
        "c": Set("acdfghiklmnoruvwxyz"),
        "d": Set("ejkmoz"),
        "e": Set("cegrstu"),
        "f": Set("ijkmor"),
        "g": Set("abdefghilmnpqrstuwy"),
        "h": Set("kmnrtu"),
        "i": Set("delmnoqrst"),
        "j": Set("emop"),
        "k": Set("eghimnprwyz"),
        "l": Set("abcikrstuvy"),
        "m": Set("acdeghklmnopqrstuvwxyz"),
        "n": Set("acefgilopruz"),
        "o": Set("m"),
        "p": Set("aefghklmnrstwy"),
        "q": Set("a"),
        "r": Set("eosuw"),
        "s": Set("abcdeghijklmnortuvxyz"),
        "t": Set("cdfghjklmnortvwz"),
        "u": Set("agksyz"),
        "v": Set("aceginu"),
        "w": Set("fs"),
        "y": Set("et"),
        "z": Set("amw"),
    ]

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

    /// The same boundary, plus the characters that mean "a scheme already claimed what follows".
    /// Without them `mailto:example.com` would have its host linkified as a document of its own.
    fileprivate var isLinkBodyOrScheme: Bool {
        isLinkBody || self == ":"
    }

    fileprivate var isHostLabel: Bool {
        isASCII && (isLetter || isNumber || self == "-")
    }

    fileprivate var isEmailLocal: Bool {
        isLetter || isNumber || ".!#$%&'*+/=?^_`{|}~-".contains(self)
    }

    fileprivate var isEmailDomain: Bool {
        isLetter || isNumber || self == "." || self == "-"
    }
}
