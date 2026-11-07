import Foundation
import HTTPTypes
import MemosAPI
import MemosCore
import OpenAPIRuntime
import SwiftUI
import Testing
import UIKit
import os

@testable import MemosFeatures

/// The memos-ng side of a memo edited on another device: one memo whose words are `before` until
/// `edit` is called, and the new words after it. The real generated client reads it, so the list
/// read, the memo read and their decoding are the app's own.
private nonisolated final class EditedElsewhereServer: ClientTransport, Sendable {
    static let memoUID = "m-edited-elsewhere"

    private struct State {
        var content: String
        var updatedAt = "2026-08-23T09:00:00Z"
    }

    private let state: OSAllocatedUnfairLock<State>

    init(content: String) {
        state = OSAllocatedUnfairLock(uncheckedState: State(content: content))
    }

    /// From now on the memo reads as another device saved it.
    func edit(to content: String) {
        state.withLock {
            $0.content = content
            $0.updatedAt = "2026-08-23T10:00:00Z"
        }
    }

    func send(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        let (content, updatedAt) = state.withLock { ($0.content, $0.updatedAt) }
        var response = HTTPResponse(status: .ok)
        response.headerFields[.contentType] = "application/json"
        let memo = """
            {"uid":"\(Self.memoUID)","owner":"fabian","mine":true,"content":"\(content)",\
            "visibility":"PRIVATE","pinned":false,"created_at":"2026-08-23T09:00:00Z",\
            "updated_at":"\(updatedAt)","archived_at":null,"tags":[],"attachments":[]}
            """
        switch operationID {
        case ResigningMemoServer.listMemos:
            let page = #"{"items":[\#(memo)],"nextCursor":null,"totalCount":null}"#
            return (response, HTTPBody(page))
        case ResigningMemoServer.getMemo:
            return (response, HTTPBody(memo))
        default:
            return (HTTPResponse(status: .notFound), nil)
        }
    }
}

/// The edit sheet over the card it was opened from, both drawn from the LIVE timeline: the card
/// reads the row the store holds now, and the sheet is handed the edit mode of that same row on
/// every pass. Feeding the sheet the live row is deliberate — it is the harshest input the sheet
/// can get, so a sheet that kept its draft only because nobody ever told it the memo had moved
/// would be caught here rather than pass by never being asked.
private struct LiveEditHost: View {
    let timeline: TimelineStore

    var body: some View {
        if let memo = timeline.memos.first {
            VStack {
                Text("Card: \(memo.content)")
                ComposeView(mode: TimelineView.editMode(for: memo)) { _ in .saved }
            }
        }
    }
}

@Suite("Memo event under an open edit")
struct MemoEventDraftTests {
    static let base = URL(string: "https://memos.example.invalid")!

    private static func textView(in view: UIView) -> UITextView? {
        if let found = view as? UITextView { return found }
        for subview in view.subviews {
            if let found = textView(in: subview) { return found }
        }
        return nil
    }

    @Test("a memo.updated while the edit sheet is open keeps the draft and updates the card")
    func anUpdateUnderAnOpenEditKeepsTheDraft() async throws {
        let server = EditedElsewhereServer(content: "before")
        let client = APIClientFactory.make(
            configuration: ServerConfiguration(baseURL: Self.base),
            token: { "memos_pat_edited" },
            transport: server
        )
        let handle = SessionHandle(client: client, generation: 1)
        let timeline = TimelineStore()
        await timeline.refresh(using: handle, baseURL: Self.base)
        try #require(timeline.memos.map(\.content) == ["before"], "the list never loaded")

        let (typed, draft, afterEvent, cardUpdated) = await PressProbe.withScreen(
            LiveEditHost(timeline: timeline), height: 852
        ) { screen -> (Bool, String?, String?, Bool) in
            _ = screen.element(labelled: "Save")
            await screen.settle(until: { Self.textView(in: screen.window) != nil })
            guard let editor = Self.textView(in: screen.window) else {
                return (false, nil, nil, false)
            }
            // Through the text view's own input path, the one the keyboard uses, so the sheet's
            // draft — its `content` state — hears it, not just the view.
            editor.insertText(" and my unsaved words")
            await screen.settle()
            let draft = editor.text

            server.edit(to: "edited on the web")
            await timeline.apply(
                MemoEvent(kind: .updated, uid: EditedElsewhereServer.memoUID),
                using: handle, baseURL: Self.base)
            await screen.settle(turns: 50, until: { screen.says("Card: edited on the web") })
            return (true, draft, editor.text, screen.says("Card: edited on the web"))
        }

        #expect(typed, "the sheet showed no editor to type into")
        let words = try #require(draft)
        #expect(words.contains("and my unsaved words"), "typing never reached the editor: \(words)")
        #expect(
            timeline.memos.map(\.content) == ["edited on the web"],
            "the event did not patch the row the store holds")
        #expect(cardUpdated, "the card beneath the sheet still shows the old words")
        #expect(
            afterEvent == words,
            "the event overwrote the open draft: \(afterEvent ?? "nil") instead of \(words)")
    }
}
