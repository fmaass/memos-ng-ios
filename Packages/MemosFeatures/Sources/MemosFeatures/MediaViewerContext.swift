import Foundation
import MemosCore
import SwiftUI

/// What the viewer says about the page on screen: its date, whose file it is, and its memo.
///
/// One resolver, per page, so the capsule, the bar and the Info sheet cannot disagree about it.
///
/// **Date.** The first of: the list's display date (`MediaPage.takenAt`), the camera's civil
/// clock, the camera's instant, the owning memo's date when the page came from that memo — else
/// none, and the capsule is not drawn. Which one answered is kept, because a display date is not
/// capture metadata and nothing may read it as such.
///
/// **Ownership.** The FILE's flag (`MemoAttachment.mine`), never the memo's.
///
/// **Memo.** The memo itself when the source carries it; else the page's memo uid, which the Info
/// sheet looks up when it opens and not before; else the file is an orphan and there is no memo.
struct MediaViewerContext: Equatable {
    enum DateOrigin: Equatable {
        case listed
        case civil
        case captured
        case memo
    }

    enum MemoLink: Equatable {
        case carried(Memo)
        case lookup(String)
        case orphan
    }

    let date: Date?
    let dateOrigin: DateOrigin?
    let ownedByMe: Bool?
    let memo: MemoLink

    static func resolve(
        _ page: MediaPage, carried memo: Memo?, timeZone: TimeZone = .current
    ) -> MediaViewerContext {
        let attachment = page.attachment
        let link: MemoLink
        if let memo {
            link = .carried(memo)
        } else if let uid = page.memoUID {
            link = .lookup(uid)
        } else {
            link = .orphan
        }
        let dated = date(of: page, carried: memo, timeZone: timeZone)
        return MediaViewerContext(
            date: dated?.date, dateOrigin: dated?.origin, ownedByMe: attachment.mine, memo: link)
    }

    private static func date(
        of page: MediaPage, carried memo: Memo?, timeZone: TimeZone
    ) -> (date: Date, origin: DateOrigin)? {
        if let listed = page.takenAt { return (listed, .listed) }
        if let text = page.attachment.captureCivil, let civil = civilDate(text, in: timeZone) {
            return (civil, .civil)
        }
        if let instant = page.attachment.captureInstant { return (instant, .captured) }
        if let memo { return (memo.createdAt, .memo) }
        return nil
    }

    /// A camera's clock as written — `2026-01-01T13:00:00`, no offset — read in `timeZone`, so the
    /// wall-clock time drawn is the one the camera wrote. Nil for anything else.
    static func civilDate(_ text: String, in timeZone: TimeZone) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss.SSSSSS"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }
}

/// Whether the viewer's chrome is drawn: one tap on the picture hides the top row, the date
/// capsule and the bar together, and the next one brings all three back.
struct MediaViewerChrome: Equatable {
    enum Part: CaseIterable, Hashable {
        case topRow
        case dateCapsule
        case bar
    }

    private(set) var hidden = false

    mutating func tapped() { hidden.toggle() }

    var shown: Set<Part> { hidden ? [] : Set(Part.allCases) }
}

/// The date of the page on screen, in two lines: the day — Today, Yesterday, a weekday for the
/// rest of the last week, else a short date — and the time under it.
struct MediaViewerDateCapsule: View {
    let date: Date
    var now: Date = Date()

    static let height: CGFloat = 44

    var body: some View {
        let calendar = Calendar.current
        VStack(spacing: 0) {
            Text(Self.dayLine(for: date, now: now, calendar: calendar, locale: .current))
                .font(.subheadline.weight(.semibold))
            Text(Self.timeLine(for: date, calendar: calendar, locale: .current))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .padding(.horizontal, DesignTokens.Space.roomy)
        .frame(minHeight: Self.height)
        .glassEffect(.regular, in: .capsule)
        .accessibilityElement(children: .combine)
    }

    static func dayLine(for date: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        let from = calendar.startOfDay(for: date)
        let to = calendar.startOfDay(for: now)
        let days = calendar.dateComponents([.day], from: from, to: to).day ?? Int.max
        switch days {
        case 0: return "Today"
        case 1: return "Yesterday"
        case 2...6:
            let style = Date.FormatStyle(
                locale: locale, calendar: calendar, timeZone: calendar.timeZone)
            return date.formatted(style.weekday(.wide))
        default:
            return date.formatted(
                Date.FormatStyle(
                    date: .abbreviated, time: .omitted, locale: locale, calendar: calendar,
                    timeZone: calendar.timeZone))
        }
    }

    static func timeLine(for date: Date, calendar: Calendar, locale: Locale) -> String {
        date.formatted(
            Date.FormatStyle(
                date: .omitted, time: .shortened, locale: locale, calendar: calendar,
                timeZone: calendar.timeZone))
    }
}
