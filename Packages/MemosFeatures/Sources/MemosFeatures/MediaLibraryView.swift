import MemosCore
import SwiftUI

/// The media library: everything the household has posted, as a grid, one cursor page at a time.
///
/// It is the SPA's Resources tab brought over (`frontend/src/views/ResourcesView.vue`) — the same
/// three filters, the same newest-first order, the same lightbox on tap — laid out the way a phone
/// lays out a library: square tiles in a grid that adapts to the width, rather than the justified
/// rows a wide browser window can afford.
///
/// Nothing here loads an image itself. A tile is an `AttachmentThumbnail`, which is the timeline's
/// tile, so the library and the feed share one loader, one cache and one set of rules about
/// signatures and retries; and a tap opens `MediaViewerView` through the same projection a memo's
/// photos open through. A second image path for the same files is the one thing this screen must
/// not become.
struct MediaLibraryView: View {
    @Environment(SessionStore.self) private var session
    @State private var library: MediaLibraryStore?
    /// The media a tile tap opened, full screen.
    @State private var viewing: MediaViewerSelection?
    /// What the zoom transition matches the viewer to: the tile it grew out of.
    @Namespace private var mediaZoom

    var body: some View {
        NavigationStack {
            Group {
                if let library {
                    content(library)
                } else {
                    ProgressView()
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Library")
            .navigationBarTitleDisplayMode(.inline)
        }
        // Outside the stack, for the reason the timeline's cover is: two presentations on one view
        // is how one of them silently stops appearing.
        .fullScreenCover(item: $viewing) { selection in
            MediaViewerView(selection: selection)
                .mediaZoomTransition(sourceID: selection.id, in: mediaZoom)
        }
        .tint(DesignTokens.accent)
        .task {
            if library == nil {
                library = MediaLibraryStore(onUnauthorized: { [session] in
                    await session.handle(.unauthorized)
                })
            }
            await load()
        }
    }

    @ViewBuilder
    private func content(_ library: MediaLibraryStore) -> some View {
        ScrollView {
            LazyVStack(spacing: DesignTokens.Space.tight) {
                if let error = library.lastError {
                    NoticeCard(text: error, tone: .error)
                        .padding(.horizontal, DesignTokens.Space.roomy)
                }
                grid(library)
                // The next page is on its way; this is what says so at the bottom of the scroll.
                if library.isLoadingMore {
                    ProgressView().padding(DesignTokens.Space.roomy)
                }
            }
            .padding(.vertical, DesignTokens.Space.tight)
        }
        // Pinned above the scroll rather than inside it: the filter is how you change what the
        // grid IS, and one that scrolls away is one you have to scroll back up to reach.
        .safeAreaInset(edge: .top) { filterBar(library) }
        .overlay {
            if library.items.isEmpty && !library.isLoading && library.lastError == nil {
                let empty = MediaLibraryPresentation.emptyState(for: library.filter)
                ContentUnavailableView(
                    empty.title,
                    systemImage: empty.symbol,
                    description: Text(empty.message)
                )
            }
        }
        .refreshable { await load() }
    }

    /// The three tabs of the filter, as a segmented control — the iOS shape of the SPA's
    /// `SelectButton`. Changing it resets the paging (`setFilter`) and reads the first page of the
    /// tab that was chosen.
    private func filterBar(_ library: MediaLibraryStore) -> some View {
        let selection = Binding(
            get: { library.filter },
            set: { chosen in
                library.setFilter(chosen)
                Task { await load() }
            }
        )
        return Picker("Filter media type", selection: selection) {
            ForEach(MediaLibraryFilter.allCases) { filter in
                Text(MediaLibraryPresentation.label(for: filter)).tag(filter)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityLabel("Filter media type")
        .padding(.horizontal, DesignTokens.Space.roomy)
        .padding(.vertical, DesignTokens.Space.snug)
        .background(.bar)
    }

    private func grid(_ library: MediaLibraryStore) -> some View {
        LazyVGrid(
            columns: [
                GridItem(
                    .adaptive(minimum: MediaLibraryPresentation.minimumTileWidth),
                    spacing: DesignTokens.Space.tight
                )
            ],
            spacing: DesignTokens.Space.tight
        ) {
            ForEach(Array(library.items.enumerated()), id: \.element.id) { pair in
                tile(pair.element)
                    // The trigger is the store's, not this view's: how close to the end is close
                    // enough is a rule with its own vectors, not a number in a view body.
                    .onAppear {
                        guard library.shouldLoadMore(after: pair.offset) else { return }
                        Task { await loadMore() }
                    }
            }
        }
        .padding(.horizontal, DesignTokens.Space.tight)
    }

    @ViewBuilder
    private func tile(_ attachment: MemoAttachment) -> some View {
        let kind = MediaLibraryPresentation.tileKind(for: attachment)
        if MediaLibraryPresentation.isOpenable(kind) {
            AttachmentThumbnail(
                attachment: attachment,
                tier: .thumb,
                slot: MemoPresentation.gridSlot
            )
            .mediaTransitionSource(id: attachment.uid, in: mediaZoom)
            .contentShape(.rect)
            .onTapGesture { open(attachment) }
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(MediaLibraryPresentation.accessibilityLabel(for: kind))
            .accessibilityHint(kind == .video ? "Plays full screen" : "Opens full screen")
        } else {
            DocumentTile(mime: attachment.mime)
        }
    }

    /// Opens the viewer over the WHOLE loaded library, at the tile that was tapped — so a swipe
    /// carries on through the grid the way it carries on through a memo's photos.
    ///
    /// The list payload carries no memo uid (`AttachmentListItem` has `orphan`, not an owner), so
    /// there is no memo to open instead; and an attachment with no memo at all — which this list
    /// deliberately includes — would have nowhere to go even if there were.
    private func open(_ attachment: MemoAttachment) {
        guard let library else { return }
        viewing = MediaViewerPresentation.viewer(for: library.items, startingAt: attachment.uid)
    }

    private func load() async {
        guard let library, let client = session.api, let baseURL = session.serverBaseURL else {
            return
        }
        await library.refresh(using: client, baseURL: baseURL)
    }

    private func loadMore() async {
        guard let library, let client = session.api, let baseURL = session.serverBaseURL else {
            return
        }
        await library.loadMore(using: client, baseURL: baseURL)
    }
}

/// A file that is neither a picture nor a clip.
///
/// It gets a tile rather than being hidden: the library is what the household has posted, and a
/// grid that silently drops the PDF somebody attached is a grid that lies about what is there.
/// Nothing about it is a failure, so nothing about it wears the failure glyph.
struct DocumentTile: View {
    let mime: String

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                ZStack {
                    Rectangle().fill(.quaternary)
                    Image(systemName: MediaLibraryPresentation.documentSymbol(for: mime))
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
            }
            .clipShape(.rect(cornerRadius: DesignTokens.Radius.tile))
            .accessibilityLabel(MediaLibraryPresentation.accessibilityLabel(for: .document))
    }
}
