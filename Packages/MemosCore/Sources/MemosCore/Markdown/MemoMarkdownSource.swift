import Foundation

/// Prepares memo content for the renderer.
///
/// Security-critical and therefore a pure function with its own tests rather than something a view
/// does inline. Two things the SPA's pipeline does that a general-purpose Markdown renderer will
/// not do on its own:
///
/// - a link whose scheme is not `http`, `https` or `mailto` must render as the plain characters
///   the author typed, never as something tappable;
/// - an image is dropped whole — `img` is not in the sanitiser's allowlist, and a removed void
///   element takes its alt text with it.
public enum MemoMarkdownSource {
    public static func prepare(_ content: String) -> String {
        neutralizeUnsafeInline(stripTagOnlyLines(content))
    }

    static func neutralizeUnsafeInline(_ source: String) -> String {
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
                let link = scanLink(chars, at: index + 1)
            {
                index = link.end
                continue
            }
            if character == "[", let link = scanLink(chars, at: index) {
                if MarkdownInline.isTappableScheme(link.destination) {
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

    private struct ScannedLink {
        var destination: String
        var end: Int
    }

    private static func scanLink(_ chars: [Character], at start: Int) -> ScannedLink? {
        guard start < chars.count, chars[start] == "[" else { return nil }
        var depth = 0
        var index = start
        var labelEnd = -1
        while index < chars.count {
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
        guard labelEnd > start, labelEnd + 1 < chars.count, chars[labelEnd + 1] == "(" else {
            return nil
        }

        var parenDepth = 0
        var destination = ""
        index = labelEnd + 1
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
                    return ScannedLink(destination: href, end: index + 1)
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
