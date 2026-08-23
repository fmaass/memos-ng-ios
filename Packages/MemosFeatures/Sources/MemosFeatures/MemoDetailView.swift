import MemosCore
import SwiftUI

/// One memo, in full.
///
/// The checkboxes are READ-ONLY in this version: writing is Phase 4's job, and a checkbox that
/// looks tappable but changes nothing is worse than one that plainly does not. The rows come from
/// the same block projection the parity fixture pins, so their order and state are the SPA's.
public struct MemoDetailView: View {
    let memo: Memo

    public init(memo: Memo) {
        self.memo = memo
    }

    private var tasks: [(text: String, checked: Bool)] {
        MemoPresentation.tasks(in: memo.content)
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(memo.createdAt, format: .dateTime.day().month().year().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)

                MemoMarkdownView(content: memo.content)

                if !tasks.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Tasks").font(.headline)
                        ForEach(Array(tasks.enumerated()), id: \.offset) { _, task in
                            Label {
                                Text(task.text)
                            } icon: {
                                Image(systemName: task.checked ? "checkmark.square" : "square")
                            }
                            .foregroundStyle(task.checked ? .secondary : .primary)
                        }
                    }
                }

                ForEach(memo.attachments) { attachment in
                    AttachmentThumbnail(attachment: attachment, tier: .mobile)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .navigationTitle(memo.pinned ? "Pinned memo" : "Memo")
        .navigationBarTitleDisplayMode(.inline)
    }
}
