import Foundation

/// Which of the memo's own pictures each local original became.
///
/// The create's answer is the only place an attachment uid can be learned, and it does not say
/// which upload each entry came from: two byte-identical captures are stored ONCE, so the answer
/// can be shorter than the list that was sent and its order alone proves nothing. What survives
/// the fold is the bytes — the server's `sha256` is taken over exactly what this device uploaded,
/// and this device still has those bytes — so identity is established by content first, and by
/// order only where the answer carries no digest at all and the two lists correspond exactly. An
/// original neither reaches stays unnamed, and an edit never names it by a guess: before the edit
/// it is uploaded again and named by that upload, or, where this device can no longer read it, the
/// edit holds and the person takes the capture back. Either way the list the edit sends names only
/// uids this device proved, so a picture the outbox cannot name is never one it deletes.
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

        // Nothing matched by content. Order is the only correspondence left, and only where the
        // answer carries NO `sha256` on any entry — a server that does not hash — and accounts for
        // every original. A digest that is present and matches nothing is the server saying these
        // are other bytes: a replayed create answers with the memo's CURRENT pictures, and one
        // another client replaced would otherwise be named as the original it replaced. One entry
        // short means a fold happened somewhere in the list, and every picture after it would be
        // named as its neighbour.
        guard answer.allSatisfy({ $0.sha256 == nil }), files.count == answer.count else {
            return [:]
        }
        for (index, file) in files.enumerated() { bound[file.id] = answer[index].uid }
        return bound
    }
}
