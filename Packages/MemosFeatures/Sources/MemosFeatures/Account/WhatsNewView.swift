import SwiftUI

/// What changed, build by build: the whole notes history, the running build's section first and
/// every earlier one after it in file order (owner 2026-10-11, MEMNG-497). Pushed from the version
/// line at the foot of the account sheet; nothing on it acts on anything.
///
/// The words are the TestFlight notes themselves — one file, so the screen cannot say something
/// the build's testers were not told. Each section's body goes through the memo renderer: the same
/// Markdown layer, theme and link policy as a memo, rather than a second one.
struct WhatsNewView: View {
    /// The build this is, as the footer reads it: `2.2.3 (45)`.
    let running: String
    var notes: [ReleaseNotes.Section] = ReleaseNotes.bundled

    static let title = "What's new"
    static let empty = "This build carries no release notes."

    var body: some View {
        let sections = ReleaseNotes.ordered(notes, running: running)
        List {
            if sections.isEmpty {
                SettingsCaption(Self.empty)
                    .cardRow()
            }
            ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                VStack(alignment: .leading, spacing: DesignTokens.Space.snug) {
                    Text(section.version)
                        .font(.headline)
                    MemoMarkdownView(content: section.body)
                }
                .padding(DesignTokens.Space.regular)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(.rect(cornerRadius: DesignTokens.Radius.card))
                .cardRow()
            }
        }
        .listStyle(.plain)
        .listRowSpacing(DesignTokens.Space.regular)
        .scrollContentBackground(.hidden)
        .background(Color(.systemGroupedBackground))
        .navigationTitle(Self.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
