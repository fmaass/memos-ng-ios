import Foundation
import MemosCore
import MemosOutbox
import SwiftUI

/// MEMNG-538 device spike — KILL DATE Tue 3 Nov 2026.
///
/// The spike's only controls, shown under the token list and only while the Settings pane's
/// "Upload spike (debug)" switch is on: mint the one-day token the share extension presents
/// (after this screen's own step-up), and hand the spike's log to the share sheet. Never on the
/// main bar (ADR-0008).
struct UploadSpikeTokenBar: View {
    let store: ManageTokensStore

    @State private var decision: UploadSpikeGrant.Decision = .notSignedIn
    @State private var problem: String?
    @State private var sharedLog: SharedLog?

    private struct SharedLog: Identifiable {
        let url: URL
        var id: URL { url }
    }

    private var canMint: Bool {
        guard decision == .mint, !store.isBusy else { return false }
        switch store.state {
        case .listed, .unlisted: return true
        default: return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Upload spike (debug)").font(.footnote.bold())
            Text(status).font(.footnote).foregroundStyle(.secondary)
            if let problem {
                Text(problem).font(.footnote).foregroundStyle(.orange)
            }
            HStack {
                Button("Mint upload-spike token") { Task { await mint() } }
                    .disabled(!canMint)
                Spacer()
                Button("Share spike log") { shareLog() }
            }
            .buttonStyle(.bordered)
            .font(.footnote)
        }
        .padding()
        .background(.bar)
        .onAppear { reread() }
        .sheet(item: $sharedLog) { ShareSheet(url: $0.url) }
    }

    private var status: String {
        switch decision {
        case .notSignedIn: return "Not signed in."
        case .mint: return "No usable spike token. Sign in above, then mint one."
        case .reuse(let expiresAt):
            return "Spike token stored, valid until \(expiresAt.formatted(.dateTime))."
        }
    }

    private func reread() {
        let stored = try? UploadSpikeGrantFile().load()
        decision = UploadSpikeGrant.decision(
            stored: stored, binding: OutboxAccountStore.live()?.current(), now: Date())
    }

    private func mint() async {
        problem = nil
        let minted = await store.createForUploadSpike { token in
            // Read here, synchronously with the keep: the account the token is bound to is the
            // one signed in at the instant the secret is stored.
            guard let binding = OutboxAccountStore.live()?.current() else { return false }
            let lifetime = TimeInterval(UploadSpike.tokenLifetimeDays) * 86_400
            let grant = UploadSpikeGrant(
                token: token.secret,
                expiresAt: token.token.expiresAt ?? Date().addingTimeInterval(lifetime),
                binding: binding)
            do {
                try UploadSpikeGrantFile().save(grant)
                return true
            } catch {
                problem = "The spike token could not be stored: \(error)"
                return false
            }
        }
        if !minted, problem == nil { problem = store.notice }
        reread()
    }

    /// A copy, so the file handed to the share sheet does not grow while it is being shared.
    private func shareLog() {
        guard let root = OutboxRepository.appGroupRoot() else {
            problem = "The app group is not reachable."
            return
        }
        let copy = URL.temporaryDirectory.appending(path: "upload-spike-log.txt")
        try? FileManager.default.removeItem(at: copy)
        do {
            try FileManager.default.copyItem(at: UploadSpike.logURL(in: root), to: copy)
            sharedLog = SharedLog(url: copy)
        } catch {
            problem = "There is no spike log yet."
        }
    }
}
