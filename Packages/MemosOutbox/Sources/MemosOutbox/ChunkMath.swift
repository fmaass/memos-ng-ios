import Foundation

/// How a file is cut into the pieces the server accepts.
///
/// Pure, and separate from anything that touches a disk or a socket, because an off-by-one here is
/// a truncated video that only shows up after it has been uploaded.
public enum ChunkMath {
    /// How many PATCHes a whole file takes. A zero-byte file takes none.
    public static func chunkCount(byteSize: Int64, chunkSize: Int) -> Int {
        guard chunkSize > 0, byteSize > 0 else { return 0 }
        let size = Int64(chunkSize)
        return Int((byteSize + size - 1) / size)
    }

    /// The length of the chunk that starts at `offset`, or nil when there is nothing left to send.
    ///
    /// The last chunk is short by design: padding it would change the file.
    public static func chunkLength(
        atOffset offset: Int64,
        byteSize: Int64,
        chunkSize: Int
    ) -> Int? {
        guard chunkSize > 0, offset >= 0, offset < byteSize else { return nil }
        let remaining = byteSize - offset
        return Int(Swift.min(remaining, Int64(chunkSize)))
    }

    /// The offsets a whole file is sent at, in order. Used by the tests and by nothing on the hot
    /// path — the drain asks for one chunk at a time.
    public static func offsets(byteSize: Int64, chunkSize: Int) -> [Int64] {
        guard chunkSize > 0, byteSize > 0 else { return [] }
        var result: [Int64] = []
        var offset: Int64 = 0
        while offset < byteSize {
            result.append(offset)
            offset += Int64(chunkSize)
        }
        return result
    }
}
