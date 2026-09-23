import Foundation

/// Which of the memo's own pictures each local original became.
///
/// The create's answer is the only place an attachment uid can be learned, and it does not say
/// which upload each entry came from: two byte-identical captures are stored ONCE, so the answer
/// can be shorter than the list that was sent and its order alone proves nothing. What survives
/// the fold is the bytes — the server's `sha256` is taken over exactly what this device uploaded,
/// and this device still has those bytes — so identity is established by content first, and by
/// order only where the two lists correspond exactly. An original neither reaches stays unnamed,
/// which the edit reads as "do not touch the memo's pictures": a picture the outbox cannot name
/// must never be a picture the outbox deletes.
public enum OutboxAttachmentIdentity {
    /// - Parameters:
    ///   - files: the originals the create sent, in capture order.
    ///   - digests: each original's own SHA-256, hex and lowercase, where it could be read.
    ///   - answer: the attachments the create's answer named.
    /// - Returns: the uid for each original that could be named, and no entry for the rest.
    public static func bind(
        files: [OutboxFile],
        digests: [UUID: String],
        answer: [ResolvedAttachment]
    ) -> [UUID: String] {
        var byDigest: [String: String] = [:]
        for attachment in answer {
            guard let sha256 = attachment.sha256?.lowercased() else { continue }
            // The earliest entry wins, which is also where the server puts a folded attachment.
            if byDigest[sha256] == nil { byDigest[sha256] = attachment.uid }
        }

        var bound: [UUID: String] = [:]
        for file in files {
            if let digest = digests[file.id]?.lowercased(), let uid = byDigest[digest] {
                bound[file.id] = uid
            }
        }
        guard bound.isEmpty else { return bound }

        // Nothing matched by content — either the store has not hashed these parts yet or this
        // device could not read its own copies. Order is then the only correspondence left, and it
        // only holds while the answer accounts for every original: one entry short means a fold
        // happened somewhere in the list, and every picture after it would be named as its
        // neighbour.
        guard files.count == answer.count else { return [:] }
        for (index, file) in files.enumerated() { bound[file.id] = answer[index].uid }
        return bound
    }
}
