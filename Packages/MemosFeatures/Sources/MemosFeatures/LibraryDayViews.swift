import MemosCore
import Observation
import SwiftUI

// The All view's day groups and the date pill over them (MEMNG-597, plan page 3929 decision 13,
// `docs/design/all-by-day-mockup.md` §2 and §3). The grouping, the frames and the day the pill
// names are MemosCore's pure functions; this is the drawing and the timing.

/// A day's heading row: the weekday in bold, the date, the count right-aligned.
struct LibraryDayHeading: View {
    let weekday: String
    let date: String
    /// The whole day's count, or nil while it is not known — the cell stays empty rather than
    /// showing how many of the day happen to be loaded.
    let count: Int?

    /// The air between one day's block and the next day's heading.
    static let air: CGFloat = 22

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.snug) {
            Text(weekday).bold()
            if !date.isEmpty {
                Text(date).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if let count {
                Text("\(count)")
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(date.isEmpty ? weekday : "\(weekday) \(date)")
        .accessibilityValue(count.map(bucketCountLabel) ?? "")
        .accessibilityAddTraits(.isHeader)
    }
}

/// Where each built heading and band starts on the page, by its place in the page's order.
///
/// A reference, kept out of SwiftUI's observation: it changes with every element the lazy stack
/// builds or lets go, and observing it would re-solve the library each time.
final class DayMarkers {
    /// The coordinate space the markers are measured in: the page itself, so a scroll moves none
    /// of them and only a layout does.
    nonisolated static let space = "library-day-page"

    private var byID: [String: (order: Int, marker: DayMarker)] = [:]
    /// Where the scroll last was.
    var line = PageLine(y: 0, atEnd: false)

    /// Whether the element's top has been brought to the line under the header — or `offset`
    /// above it — or the scroll has gone as far as it can.
    func reached(_ id: String, above offset: Double = 0) -> Bool {
        guard let top = byID[id]?.marker.top else { return false }
        // At its end only once the scroll has moved: the lazy stack's first passes report a page
        // shorter than it is — even one that fits the screen — and a landing settled on one of
        // them would never be brought at all. A page that truly fits has nowhere to scroll, so
        // its landing waiting on costs nothing.
        return abs(top + offset - line.y) <= 1 || (line.atEnd && line.y > 1)
    }

    /// The built element reaching below the line — a heading or a band — and how far the line is
    /// past its top, as `first(reaching:among:)` reads it.
    func atLine() -> (id: String, offset: Double)? {
        let y = line.y
        let down = byID.map { (id: $0.key, top: $0.value.marker.top) }.sorted { $0.top < $1.top }
        for (place, element) in down.enumerated() {
            let end = place + 1 < down.count ? down[place + 1].top : .infinity
            if end > y + 1 { return (element.id, y - element.top) }
        }
        return nil
    }

    /// Where the element starts on the page, while it is built.
    func top(of id: String) -> Double? { byID[id]?.marker.top }

    /// Whether a built day heading reaches into the page's span `top`..<`bottom` (MEMNG-676):
    /// the date pill's place under the header, which a heading scrolling past would be drawn
    /// beneath. A heading ends where the next built element starts, as `atLine()` reads it.
    func headingCrosses(from top: Double, to bottom: Double) -> Bool {
        let down = byID.map { (id: $0.key, marker: $0.value.marker) }
            .sorted { $0.marker.top < $1.marker.top }
        for (place, element) in down.enumerated()
        where element.id == LibraryDayGroup.headingID(element.marker.key) {
            let end = place + 1 < down.count ? down[place + 1].marker.top : .infinity
            if element.marker.top < bottom, end > top { return true }
        }
        return false
    }

    func place(_ id: String, day: String, order: Int, top: CGFloat) {
        byID[id] = (order, DayMarker(key: day, top: Double(top)))
    }

    func remove(_ id: String) { byID[id] = nil }

    /// The first of `ids`, down the page, that still reaches below `y` — the band at the top of
    /// the screen (MEMNG-818). An element ends where the next built one starts, because the stack
    /// builds a run of rows with nothing missing between them; and the run reaches above and below
    /// the screen, so the first built element is not the first one seen.
    func first(reaching y: Double, among ids: Set<String>) -> String? {
        let down = byID.map { (id: $0.key, top: $0.value.marker.top) }.sorted { $0.top < $1.top }
        for (place, element) in down.enumerated() where ids.contains(element.id) {
            let end = place + 1 < down.count ? down[place + 1].top : .infinity
            if end > y + 1 { return element.id }
        }
        return nil
    }

    /// In the page's order. A band as well as a heading marks its day, so a long day whose heading
    /// the lazy stack has let go of above the screen is still the day at the top.
    var inOrder: [DayMarker] {
        byID.values.sorted { lhs, rhs in
            lhs.order != rhs.order ? lhs.order < rhs.order : lhs.marker.top < rhs.marker.top
        }
        .map(\.marker)
    }
}

/// The line under the header in the page's own coordinates, and whether the scroll is at its end.
nonisolated struct PageLine: Equatable, Sendable {
    let y: Double
    let atEnd: Bool

    init(y: Double, atEnd: Bool) {
        self.y = y
        self.atEnd = atEnd
    }

    init(_ geometry: ScrollGeometry) {
        let furthest =
            geometry.contentSize.height + geometry.contentInsets.bottom
            - geometry.containerSize.height
        y = Double(geometry.contentOffset.y + geometry.contentInsets.top)
        // Before the first layout both sizes are zero, which would read as a scroll at its end —
        // and a landing settled on it before the scroll could move at all.
        let measured = geometry.contentSize.height > 0 && geometry.containerSize.height > 0
        atEnd = measured && geometry.contentOffset.y >= furthest - 1
    }
}

/// What a heading or band of the lazy stack reports while it is built: that it is on or beside
/// the screen (`LibraryGrid`'s landing), and where on the page it starts (the date pill).
struct BuiltMarker: ViewModifier {
    let id: String
    let day: String
    let order: Int
    let onScreen: RowsOnScreen
    let markers: DayMarkers
    /// Told each time the element is built, for the landing's re-ask.
    let reached: () -> Void

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.frame(in: .named(DayMarkers.space)).minY
            } action: { top in
                markers.place(id, day: day, order: order, top: top)
            }
            .onAppear {
                onScreen.rows.insert(id)
                reached()
            }
            .onDisappear {
                onScreen.rows.remove(id)
                markers.remove(id)
            }
    }
}

/// The date pill's state: which day it names and whether it shows.
///
/// Every scroll shows it and starts its fade again; it hides one second after the last one. The
/// serial is what the fade waits on, so a scroll during the wait cancels that wait by starting
/// the next (`DatePill`'s `task(id:)`).
@MainActor
@Observable
final class DatePillModel {
    /// How long the pill stays after the scrolling stops.
    static let linger: Duration = .seconds(1)

    private(set) var day: String?
    private(set) var shown = false
    private(set) var serial = 0
    /// A day heading is passing under the pill (MEMNG-676): it steps aside, unanimated, so the
    /// heading — which names a day itself — is never drawn beneath it, and returns once it is past.
    var covered = false
    /// The pill's drawn height, which `covered` is judged over.
    var height: Double = 0

    /// A scroll moved the page; `top` is the day now at the top of the screen, or nil at the top
    /// of the page, where no heading has reached the line yet and the pill stays hidden.
    func scrolled(to top: String?) {
        if day != top { day = top }
        if !shown, top != nil { shown = true }
        if top == nil, shown { shown = false }
        serial &+= 1
    }

    /// The fade, when no scroll has come since the one numbered `serial`.
    func fade(after serial: Int) {
        guard serial == self.serial else { return }
        shown = false
    }
}

/// The date while scrolling: a glass capsule, top centre under the header and clear of its
/// buttons, naming the day at the top of the screen ("Sat · 27 Sep 2026"). A tap opens Months at
/// that day's month — the way up.
struct DatePill: View {
    let model: DatePillModel
    let showMonth: (String) -> Void

    /// What a test and VoiceOver's rotor find the pill by.
    static let identifier = "date-pill"
    /// How far under the header the pill stands.
    static let gap = DesignTokens.Space.snug

    var body: some View {
        Group {
            if model.shown, !model.covered, let day = model.day {
                Button {
                    showMonth(String(day.prefix(7)))
                } label: {
                    Text(dayPillLabel(day))
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, DesignTokens.Space.roomy)
                        .padding(.vertical, DesignTokens.Space.snug)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .capsule)
                .onGeometryChange(for: Double.self) {
                    Double($0.size.height)
                } action: {
                    model.height = $0
                }
                .accessibilityIdentifier(Self.identifier)
                .accessibilityHint("Opens Months at this month")
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.3), value: model.shown)
        .task(id: model.serial) {
            let serial = model.serial
            try? await Task.sleep(for: DatePillModel.linger)
            guard !Task.isCancelled else { return }
            model.fade(after: serial)
        }
    }
}
