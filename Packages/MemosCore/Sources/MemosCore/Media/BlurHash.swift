import Foundation

/// The BlurHash the server already computed, turned back into pixels.
///
/// Every attachment arrives with a `blurhash` — a 20-30 character summary of the picture the
/// server made when it derived the thumbnails. It costs nothing to send and it is the only thing
/// the app has to put on screen while a photo is still coming down the wire. Decoding it is pure
/// arithmetic over a handful of cosine terms, so it happens inline: a 32x32 decode is a few tens
/// of thousands of multiplications, which is cheaper than the layout pass that follows it.
///
/// The algorithm is the reference one (github.com/woltapp/blurhash); the encoder on the other end
/// is `app/services/blurhash_pure.py` in memos-ng, and the test vectors in `BlurHashTests` were
/// produced BY that encoder, so this decoder is held to what actually reaches the phone rather
/// than to a restatement of itself.
public enum BlurHash {
    /// The 83-character alphabet the format is written in. Position IS value.
    static let alphabet = Array(
        "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
            + "#$%*+,-.:;=?@[]^_{|}~"
    )

    /// Decodes to straight RGBA bytes, four per pixel, row-major, alpha always 255.
    ///
    /// Returns `nil` for anything that is not a well-formed hash — a truncated string, a
    /// character outside the alphabet, a length that disagrees with the component count in its
    /// own first character. A placeholder is not worth a crash.
    public static func decode(
        _ hash: String,
        width: Int,
        height: Int,
        punch: Float = 1
    ) -> [UInt8]? {
        guard width > 0, height > 0 else { return nil }
        let characters = Array(hash)
        guard characters.count >= 6 else { return nil }
        guard let sizeFlag = base83(characters[0..<1]) else { return nil }
        let componentsX = (sizeFlag % 9) + 1
        let componentsY = (sizeFlag / 9) + 1
        guard characters.count == 4 + 2 * componentsX * componentsY else { return nil }
        guard let quantisedMaximum = base83(characters[1..<2]) else { return nil }
        let maximum = Float(quantisedMaximum + 1) / 166

        var colors = [(r: Float, g: Float, b: Float)]()
        colors.reserveCapacity(componentsX * componentsY)
        guard let dc = base83(characters[2..<6]) else { return nil }
        colors.append(
            (
                sRGBToLinear((dc >> 16) & 255),
                sRGBToLinear((dc >> 8) & 255),
                sRGBToLinear(dc & 255)
            )
        )
        for index in 1..<(componentsX * componentsY) {
            let start = 4 + index * 2
            guard let value = base83(characters[start..<(start + 2)]) else { return nil }
            let quantisedR = value / (19 * 19)
            let quantisedG = (value / 19) % 19
            let quantisedB = value % 19
            colors.append(
                (
                    signPow((Float(quantisedR) - 9) / 9) * maximum * punch,
                    signPow((Float(quantisedG) - 9) / 9) * maximum * punch,
                    signPow((Float(quantisedB) - 9) / 9) * maximum * punch
                )
            )
        }

        // The two cosine tables are separable, so they are built once instead of per pixel: the
        // inner loop is then three multiply-adds and no transcendental calls at all.
        var cosinesX = [Float](repeating: 0, count: width * componentsX)
        for x in 0..<width {
            for i in 0..<componentsX {
                cosinesX[x * componentsX + i] =
                    cos(Float.pi * Float(x) * Float(i) / Float(width))
            }
        }
        var cosinesY = [Float](repeating: 0, count: height * componentsY)
        for y in 0..<height {
            for j in 0..<componentsY {
                cosinesY[y * componentsY + j] =
                    cos(Float.pi * Float(y) * Float(j) / Float(height))
            }
        }

        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                var r: Float = 0
                var g: Float = 0
                var b: Float = 0
                for j in 0..<componentsY {
                    let cosineY = cosinesY[y * componentsY + j]
                    for i in 0..<componentsX {
                        let basis = cosinesX[x * componentsX + i] * cosineY
                        let color = colors[i + j * componentsX]
                        r += color.r * basis
                        g += color.g * basis
                        b += color.b * basis
                    }
                }
                let offset = (y * width + x) * 4
                pixels[offset] = linearToSRGB(r)
                pixels[offset + 1] = linearToSRGB(g)
                pixels[offset + 2] = linearToSRGB(b)
            }
        }
        return pixels
    }

    /// The average colour the hash carries, as its own sRGB bytes — the DC term, read without
    /// decoding anything else. It is what a one-pixel decode would give, for a fraction of the
    /// work, and it is enough wherever a tint rather than a picture is wanted.
    public static func averageColor(_ hash: String) -> (r: UInt8, g: UInt8, b: UInt8)? {
        let characters = Array(hash)
        guard characters.count >= 6, let dc = base83(characters[2..<6]) else { return nil }
        return (UInt8((dc >> 16) & 255), UInt8((dc >> 8) & 255), UInt8(dc & 255))
    }

    static func base83(_ characters: ArraySlice<Character>) -> Int? {
        var value = 0
        for character in characters {
            guard let digit = alphabet.firstIndex(of: character) else { return nil }
            value = value * 83 + digit
        }
        return value
    }

    static func sRGBToLinear(_ component: Int) -> Float {
        let value = Float(component) / 255
        return value <= 0.04045
            ? value / 12.92
            : pow((value + 0.055) / 1.055, 2.4)
    }

    static func linearToSRGB(_ value: Float) -> UInt8 {
        let clamped = min(max(value, 0), 1)
        let encoded =
            clamped <= 0.0031308
            ? clamped * 12.92
            : 1.055 * pow(clamped, 1 / 2.4) - 0.055
        return UInt8(min(max((encoded * 255).rounded(), 0), 255))
    }

    static func signPow(_ value: Float) -> Float {
        // The exponent is 2, so this is |v|*v — written out because the sign has to survive it.
        value * abs(value)
    }
}
