import MemosCore
import SwiftUI
import Testing
import UIKit

@testable import MemosFeatures

/// Hosting the grid in a real window and asserting tiles get PLACED — the pass MEMNG-206 proved
/// was missing: the solver had tests, the tiles had tests, and the round trip that turns a store
/// full of files into laid-out rows had none, so a width that never lifted off zero shipped as a
/// library that renders nothing.
@MainActor
@Suite("Library grid placement")
struct MediaLibraryRenderTests {
    /// The grid under a namespace, which only a view can declare.
    private struct Harness: View {
        let items: [LibraryRow]
        var landing: LibraryLanding?
        var landed: (LibraryLanding) -> Void = { _ in }
        /// The store's list generation, which a test moves without drawing the harness again.
        var generation = GenerationBox(0)
        var dayBuckets: [LibraryBucket]?
        var showMonth: (String) -> Void = { _ in }
        @Namespace private var zoom

        var body: some View {
            LibraryGrid(
                items: items,
                errorText: nil,
                loadingMore: false,
                zoom: zoom,
                wantsMore: { _ in false },
                open: { _ in },
                fetch: { _, _ in },
                loadMore: {},
                landing: landing,
                landed: landed,
                listGeneration: { generation.value },
                dayBuckets: dayBuckets,
                showMonth: showMonth
            )
        }
    }

    /// The library the defect shipped against, in miniature: photographs in their own shapes, a
    /// clip, and a file with no dimensions at all (a migrated original the server never measured).
    /// All of it taken in one month, so it is one section under one header.
    private static let items: [LibraryRow] = [
        MediaViewerPageTests.image("lib-a", width: 4000, height: 3000),
        MediaViewerPageTests.image("lib-b", width: 3000, height: 4000),
        MediaViewerPageTests.image("lib-c", width: 8192, height: 2048),
        MediaViewerPageTests.image("lib-d", width: 2000, height: 2000),
        MediaViewerPageTests.video("lib-e"),
        MediaViewerPageTests.image("lib-f", width: 4032, height: 3024),
        MediaViewerPageTests.other("lib-g", mime: "application/pdf"),
        MediaViewerPageTests.image("lib-h", width: 2448, height: 3264),
    ].map { MediaLibraryRenderTests.row($0, takenAt: MediaLibraryRenderTests.september) }

    /// The library's calendar, which the grid cuts in whatever the simulator's zone is.
    private static let zone = libraryTimeZone
    /// Mid-month in either zone a reader could be in, so no fixture sits on a month's edge.
    private static let september = Date(timeIntervalSince1970: 1_789_387_200)  // 2026-09-14 12:00Z
    private static let august = Date(timeIntervalSince1970: 1_786_708_800)  // 2026-08-14 12:00Z

    private static func row(_ attachment: MemoAttachment, takenAt: Date) -> LibraryRow {
        LibraryRow(
            attachment: attachment, takenAt: takenAt, mine: true, filename: attachment.uid)
    }

    /// MEMNG-587: the Months tap builds a NEW grid, and the jump may have landed before it exists
    /// or before it has measured its width. Either way the landing is already set when the grid
    /// could first scroll, so a grid that only answers a CHANGE of landing never scrolls at all.
    @Test("a grid built with a landing already set scrolls to it, once")
    func gridScrollsToALandingItWasBuiltWith() async throws {
        let filler = (0..<40).map {
            Self.row(
                MediaViewerPageTests.image("fill-\($0)", width: 1000, height: 1000),
                takenAt: Self.september)
        }
        let target = Self.row(
            MediaViewerPageTests.image("target", width: 1000, height: 1000), takenAt: Self.august)
        let landing = LibraryLanding(day: "2026-08-14", rowID: "target", serial: 1)
        let consumed = LockedLandings()
        // On the test host's own scene (as `StackChromeTests` does): a window belonging to no scene
        // took the first scroll the grid asked for and none after it.
        let frame = CGRect(origin: .zero, size: CGSize(width: 390, height: 844))
        let window: UIWindow
        if let scene = UIApplication.shared.connectedScenes.first(where: { $0 is UIWindowScene })
            as? UIWindowScene
        {
            window = UIWindow(windowScene: scene)
            window.frame = frame
        } else {
            window = UIWindow(frame: frame)
        }
        window.rootViewController = UIHostingController(
            rootView: Harness(
                items: filler + [target], landing: landing, landed: { consumed.append($0) }))
        window.makeKeyAndVisible()

        // The row coming into view is told after the scroll lands, so both are waited for; then a
        // few more passes, in which a second report of the same landing would arrive.
        // The landing's row is the grid's last, so a scroll brought to it rests at the bottom.
        var offset: CGFloat = 0
        var bottom: CGFloat = .infinity
        var settledPasses = 0
        for _ in 0..<80 where settledPasses < 5 {
            try await Task.sleep(for: .milliseconds(50))
            window.layoutIfNeeded()
            (offset, bottom) = Self.scrollOffset(in: window)
            if offset >= bottom - 1, !consumed.all.isEmpty { settledPasses += 1 }
        }
        window.isHidden = true
        #expect(offset > 0, "the grid never scrolled to the landing it was built with")
        #expect(offset >= bottom - 1, "the scroll stopped short of the landing's row")
        #expect(consumed.all == [landing], "the landing was not reported scrolled to exactly once")
    }

    @Test("a grid holding files places them once it has a real frame")
    func gridPlacesTilesInARealFrame() async throws {
        let window = UIWindow(frame: CGRect(origin: .zero, size: CGSize(width: 390, height: 844)))
        window.rootViewController = UIHostingController(rootView: Harness(items: Self.items))
        window.makeKeyAndVisible()
        window.layoutIfNeeded()

        // MEMNG-597: what the day groups pack for the width the grid must derive — the window's
        // 390, less the block's 12 pt inset either side. The grid draws that packing as a scroll
        // whose content is each month's header, each day's heading and each band of its block,
        // their spacing and the stack's vertical padding, so the content height IS the placement,
        // readable from outside the hierarchy. A header's and a heading's heights are the numbers
        // the geometry does not know, so they are measured, by UIKit, at the same width.
        let inset = DesignTokens.Space.regular
        let block = 390 - 2 * inset
        let sections = MediaLibraryPresentation.daySections(for: Self.items, timeZone: Self.zone)
        let days = sections.flatMap(\.days)
        let bands = days.flatMap(\.bands)
        #expect(
            bands.count > 1, "the fixture must pack into bands — otherwise this asserts nothing")
        let header = LayoutProbe.size(
            LibraryMonthHeader(label: "September 2026"), width: 390 - 2 * DesignTokens.Space.tight,
            height: LayoutProbe.unbounded
        ).height
        let heading = LayoutProbe.size(
            LibraryDayHeading(weekday: "Mon", date: "14 Sep", count: nil), width: block,
            height: LayoutProbe.unbounded
        ).height
        let bandHeights = days.reduce(CGFloat(0)) { sum, day in
            sum
                + day.bands.enumerated().reduce(CGFloat(0)) { inner, entry in
                    inner
                        + MonthMosaicGeometry.frames(
                            for: entry.element.pictures.map(\.slot), width: block,
                            gap: DesignTokens.Space.hair
                        ).height
                        + (entry.offset == day.bands.count - 1
                            ? LibraryDayHeading.air : DesignTokens.Space.hair)
                }
        }
        let expected =
            CGFloat(sections.count) * (header + DesignTokens.Space.snug)
            + CGFloat(days.count) * (heading + DesignTokens.Space.snug)
            + bandHeights + 2 * DesignTokens.Space.tight
        var placed: CGFloat = 0
        for _ in 0..<60 where abs(placed - expected) > 2 {
            try await Task.sleep(for: .milliseconds(50))
            window.layoutIfNeeded()
            placed = Self.scrollContentHeight(in: window)
        }
        window.isHidden = true
        #expect(
            abs(placed - expected) <= 2,
            "the grid placed \(placed)pt of content where the day groups pack \(expected)pt")
    }

    @Test("a two-month page shows a header per month, in the list's order")
    func headerPerMonth() async throws {
        let september = (0..<3).map {
            Self.row(
                MediaViewerPageTests.image("sep-\($0)", width: 4000, height: 3000),
                takenAt: Self.september)
        }
        let august = (0..<3).map {
            Self.row(
                MediaViewerPageTests.image("aug-\($0)", width: 3000, height: 4000),
                takenAt: Self.august)
        }
        let window = UIWindow(frame: CGRect(origin: .zero, size: CGSize(width: 390, height: 844)))
        window.rootViewController = UIHostingController(
            rootView: Harness(items: september + august))
        window.makeKeyAndVisible()
        window.layoutIfNeeded()

        let months: Set<String> = ["September 2026", "August 2026"]
        var headers: [String] = []
        for _ in 0..<60 where headers.count < 2 {
            try await Task.sleep(for: .milliseconds(50))
            window.layoutIfNeeded()
            var found: [String] = []
            Self.collectLabels(window, into: &found)
            headers = found.filter(months.contains).reduce(into: []) { seen, label in
                if !seen.contains(label) { seen.append(label) }
            }
        }
        window.isHidden = true
        // Newest first, as the list came: a grid that re-sorted its sections, or drew one header
        // for the whole page, fails here.
        #expect(headers == ["September 2026", "August 2026"])
    }

    /// Plan page 3929 decision 10: a large title with the subtitle under it, then on the right the
    /// round filter button and, after it, the Select capsule — drawn, and inert where there is
    /// nothing to select (no `select` action: Years and Months).
    @Test("the header draws the title, the subtitle, the filter button and a disabled Select")
    func headerChrome() async throws {
        let subtitle = "Videos · Oldest First · #travel"
        let window = UIWindow(frame: CGRect(origin: .zero, size: CGSize(width: 390, height: 844)))
        window.rootViewController = UIHostingController(
            rootView: VStack {
                LibraryHeader(subtitle: subtitle) { Text("row") }
                Spacer()
            })
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        var found: [NSObject] = []
        for _ in 0..<60 {
            try await Task.sleep(for: .milliseconds(50))
            window.layoutIfNeeded()
            found = []
            Self.collectElements(window, into: &found)
            if found.contains(where: { $0.accessibilityLabel == "Select" }) { break }
        }
        func element(_ label: String) -> NSObject? {
            found.first { $0.accessibilityLabel == label }
        }
        let title = try #require(element("Library"), "no title")
        #expect(title.accessibilityTraits.contains(.header), "the title is not a heading")
        #expect(element(subtitle) != nil, "no subtitle line")
        let options = try #require(element("Filter"), "no filter button")
        let select = try #require(element("Select"), "no Select capsule")
        #expect(!options.accessibilityTraits.contains(.notEnabled), "the filter button is inert")
        #expect(select.accessibilityTraits.contains(.notEnabled), "Select is live too early")
        // Right of the title, the filter button first and the capsule after it.
        let left = title.accessibilityFrame.midX
        let middle = options.accessibilityFrame.midX
        let right = select.accessibilityFrame.midX
        #expect(left < middle && middle < right, "x: title \(left), ••• \(middle), \(right)")
    }

    /// MEMNG-756: the Library's left edges are one. The month over a day's rows and the day's
    /// heading start where the header's title does, at its 16 pt inset; the bands under them keep
    /// their own 12 pt.
    @Test("the month header and the day heading start at the header title's edge")
    func monthAndDayShareTheTitleEdge() async throws {
        let header = UIWindow(frame: CGRect(origin: .zero, size: CGSize(width: 390, height: 844)))
        header.rootViewController = UIHostingController(
            rootView: VStack {
                LibraryHeader(subtitle: "All") { Text("row") }
                Spacer()
            })
        header.makeKeyAndVisible()
        let window = Self.show(Harness(items: Self.day("mon", 3, at: Self.noon(14))))
        defer {
            header.isHidden = true
            header.rootViewController = nil
            window.isHidden = true
        }
        var title: NSObject?
        var month: NSObject?
        var day: NSObject?
        for _ in 0..<60 where title == nil || month == nil || day == nil {
            try await Task.sleep(for: .milliseconds(50))
            header.layoutIfNeeded()
            window.layoutIfNeeded()
            title = Self.element("Library", in: header)
            month = Self.element("September 2026", in: window)
            day = Self.element("Mon 14 Sep", in: window)
        }
        let edge = try #require(title, "no header title").accessibilityFrame.minX
        let monthEdge = try #require(month, "no month header").accessibilityFrame.minX
        let dayEdge = try #require(day, "no day heading").accessibilityFrame.minX
        #expect(abs(edge - DesignTokens.Space.roomy) < 0.5, "the title starts at \(edge)")
        #expect(abs(monthEdge - edge) < 0.5, "the month at \(monthEdge), the title at \(edge)")
        #expect(abs(dayEdge - edge) < 0.5, "the day heading at \(dayEdge), the title at \(edge)")
    }

    /// MEMNG-757: Collections wears the Library's header. Each tab's title starts at the Library
    /// title's edge, and its last control stands where the Library's Select capsule does — the
    /// same height and middle, and the same trailing edge, the header's inset from the window's.
    /// The Library's own case holds the reference to the numbers it is measured by.
    @Test(
        "each tab's header puts its title and its last control where the Library's stand",
        arguments: [MainTab.library, MainTab.collections]
    )
    func headerMatchesTheLibrarys(tab: MainTab) async throws {
        let width: CGFloat = 390
        let reference = try await Self.frames(
            of: LibraryHeader(subtitle: "All", select: {}) { Text("row") },
            labels: ["Library", "Select"], width: width)
        var measured = reference
        if tab == .collections {
            measured = try await Self.frames(
                of: CollectionsScreen.header(tripCount: 3, newTrip: {}),
                labels: [MainTab.collections.title, CollectionsScreen.newTripButton],
                width: width)
        }
        try #require(reference.count == 2, "the Library header read \(reference)")
        try #require(measured.count == 2, "the \(tab) header read \(measured)")
        let title = measured[0]
        let control = measured[1]
        let capsule = reference[1]
        #expect(abs(reference[0].minX - DesignTokens.Space.roomy) < 0.5, "Library at \(reference)")
        #expect(abs(title.minX - reference[0].minX) < 0.5, "\(tab) title \(title)")
        #expect(abs(capsule.height - HeaderGlassCircle.control) < 0.5, "capsule \(capsule)")
        #expect(abs(control.height - capsule.height) < 0.5, "\(tab) control \(control)")
        #expect(abs(control.midY - capsule.midY) < 0.5, "\(tab) control \(control)")
        #expect(abs(control.maxX - capsule.maxX) < 0.5, "\(tab) control \(control)")
        #expect(abs(width - capsule.maxX - DesignTokens.Space.roomy) < 0.5, "capsule \(capsule)")
    }

    /// Hosts `view` at the top of a real window `width` wide and reads, while the window stands,
    /// the frame of the element labelled each of `labels`, in order; fewer when one never shows.
    private static func frames(
        of view: some View, labels: [String], width: CGFloat
    ) async throws -> [CGRect] {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 844))
        window.rootViewController = UIHostingController(
            rootView: VStack {
                view
                Spacer()
            })
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        var frames: [CGRect] = []
        for _ in 0..<60 where frames.count < labels.count {
            try await Task.sleep(for: .milliseconds(50))
            window.layoutIfNeeded()
            var found: [NSObject] = []
            collectElements(window, into: &found)
            frames = labels.compactMap { label in
                found.first { $0.accessibilityLabel == label }?.accessibilityFrame
            }
        }
        return frames
    }

    /// Hosts `view` in a real window until an element labelled `waitFor` appears, and returns
    /// every labelled element it holds.
    private static func elements(of view: some View, waitFor: String) async throws -> [NSObject] {
        let window = UIWindow(frame: CGRect(origin: .zero, size: CGSize(width: 390, height: 844)))
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        var found: [NSObject] = []
        for _ in 0..<60 {
            try await Task.sleep(for: .milliseconds(50))
            window.layoutIfNeeded()
            found = []
            collectElements(window, into: &found)
            if found.contains(where: { $0.accessibilityLabel == waitFor }) { break }
        }
        return found
    }

    /// MEMNG-588: on All the Select capsule is live.
    @Test("the Select capsule is live where there are files to select")
    func selectCapsuleIsLiveInAll() async throws {
        let found = try await Self.elements(
            of: LibraryHeader(subtitle: "All", select: {}) { Text("row") }, waitFor: "Select")
        let select = try #require(found.first { $0.accessibilityLabel == "Select" })
        #expect(!select.accessibilityTraits.contains(.notEnabled), "Select is still inert in All")
    }

    /// The header's controls, leading to trailing: what carries the button trait, each CONTROL
    /// once. The walk can meet one control twice — a view and the element it hosts — at one frame;
    /// two controls never share a frame, so two close buttons count as two.
    private static func controls(in found: [NSObject]) -> [String] {
        var seen: Set<String> = []
        return found.filter { $0.accessibilityTraits.contains(.button) }
            .filter { element in
                let frame = element.accessibilityFrame.integral
                let key =
                    "\(element.accessibilityLabel ?? "")@\(frame.minX),\(frame.minY),"
                    + "\(frame.width),\(frame.height)"
                return seen.insert(key).inserted
            }
            .sorted { $0.accessibilityFrame.minX < $1.accessibilityFrame.minX }
            .compactMap(\.accessibilityLabel)
    }

    /// The bands of ink, one under another, that the glyph inside `frame` draws, read from the
    /// hosting view as drawn over its middle half of columns and the button's whole height (the
    /// glass sets its glyph below the centre), with the darkest value of each row as the evidence:
    /// the filter glyph is three lines stacked, an ellipsis one row of dots. Ink is measured
    /// against the lightest row, not a fixed grey, because the glass draws its symbol softened.
    private static func inkBands(
        in frame: CGRect, of view: UIView
    ) -> (bands: Int, profile: String) {
        let scale: CGFloat = 3
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        var drew = false
        let image = UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { context in
            UIColor.white.setFill()
            context.fill(view.bounds)
            drew = view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        guard drew, let whole = image.cgImage else { return (-1, "drew \(drew)") }
        let inner = view.convert(frame, from: nil).insetBy(dx: frame.width / 4, dy: 0)
        let pixels = CGRect(
            x: inner.minX * scale, y: inner.minY * scale, width: inner.width * scale,
            height: inner.height * scale
        ).integral
        guard let drawn = whole.cropping(to: pixels) else { return (-1, "no crop \(pixels)") }
        let width = drawn.width
        let height = drawn.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { raw in
            let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.draw(drawn, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        let darkest: [Double] = (0..<height).map { y in
            (0..<width).map { x in
                let at = (y * width + x) * 4
                let weighted =
                    0.299 * Double(bytes[at]) + 0.587 * Double(bytes[at + 1])
                    + 0.114 * Double(bytes[at + 2])
                return weighted / 255
            }.min() ?? 1
        }
        let background = darkest.max() ?? 1
        var bands = 0
        var inBand = false
        for value in darkest {
            let inked = value < background - 0.2
            if inked && !inBand { bands += 1 }
            inBand = inked
        }
        let profile = darkest.map { String(Int(($0 * 9).rounded())) }.joined()
        return (bands, "frame \(frame) \(width)x\(height) darkest-by-row \(profile)")
    }

    /// MEMNG-779 (WPN-12 phase 1): browsing, the header holds exactly the round filter button and
    /// Select, and the round button DRAWS the filter glyph — three stacked lines, read from the
    /// window, not from a constant; in select mode with nothing chosen there is no Select All or
    /// Deselect All, and the trailing capsule holds one control, the close button — its actions
    /// menu has no rows on the Library.
    @Test("the header shows the filter button and Select; select mode shows only its close button")
    func filterHeaderAndSelectChrome() async throws {
        let window = UIWindow(frame: CGRect(origin: .zero, size: CGSize(width: 390, height: 844)))
        window.overrideUserInterfaceStyle = .light
        window.rootViewController = UIHostingController(
            rootView: VStack {
                LibraryHeader(subtitle: "All", select: {}) { Text("row") }
                Spacer()
            }
            .background(Color.white))
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        var browsing: [NSObject] = []
        for _ in 0..<60 {
            try await Task.sleep(for: .milliseconds(50))
            window.layoutIfNeeded()
            browsing = []
            Self.collectElements(window, into: &browsing)
            if browsing.contains(where: { $0.accessibilityLabel == "Select" }) { break }
        }
        #expect(
            Self.controls(in: browsing) == ["Filter", "Select"],
            "browsing controls: \(Self.controls(in: browsing))")
        let filter = try #require(browsing.first { $0.accessibilityLabel == "Filter" })
        let hosted = try #require(window.rootViewController?.view)
        let ink = Self.inkBands(in: filter.accessibilityFrame, of: hosted)
        #expect(
            ink.bands == 3, "the round button draws \(ink.bands) band(s) of ink: \(ink.profile)")

        let selecting = try await Self.elements(
            of: LibraryHeader(subtitle: "All", select: {}, selecting: true) { Text("row") },
            waitFor: "Close")
        let labels = selecting.compactMap(\.accessibilityLabel)
        #expect(!labels.contains("Select All"), "a Select All control: \(labels)")
        #expect(!labels.contains("Deselect All"), "a Deselect All control: \(labels)")
        #expect(
            Self.controls(in: selecting) == ["Close"],
            "select mode controls: \(Self.controls(in: selecting))")
    }

    /// MEMNG-779: once select mode's actions menu has rows (WPN-14 gives the Library some), the
    /// trailing capsule holds that menu and then the close button.
    @Test("select mode's capsule holds the actions menu and the close button once it has rows")
    func selectChromeWithRows() async throws {
        let rows = [
            SelectAction(id: "share", title: "Share", systemImage: "square.and.arrow.up") {}
        ]
        let found = try await Self.elements(
            of: SelectChrome(menuRows: rows, close: {}), waitFor: "Close")
        #expect(
            Self.controls(in: found) == ["More", "Close"],
            "capsule controls: \(Self.controls(in: found))")
    }

    /// MEMNG-588 and MEMNG-589: the bottom bar says how many are chosen, and share and delete take
    /// a tap while something is chosen and nothing is running.
    @Test("the select toolbar counts the selection, with share and delete live")
    func selectToolbar() async throws {
        let found = try await Self.elements(
            of: VStack {
                Spacer()
                LibrarySelectToolbar(
                    count: 2, ownCount: 2, isSharing: false, isDeleting: false, share: {},
                    delete: {})
            },
            waitFor: "2 Items Selected")
        func element(_ label: String) -> NSObject? {
            found.first { $0.accessibilityLabel == label }
        }
        #expect(element("2 Items Selected") != nil, "no count line")
        let share = try #require(element("Share"), "no share button")
        let delete = try #require(element("Delete"), "no delete button")
        #expect(!share.accessibilityTraits.contains(.notEnabled), "share is inert")
        #expect(!delete.accessibilityTraits.contains(.notEnabled), "delete is inert")

        let none = try await Self.elements(
            of: LibrarySelectToolbar(
                count: 0, ownCount: 0, isSharing: false, isDeleting: false, share: {},
                delete: {}),
            waitFor: "0 Items Selected")
        let idle = try #require(none.first { $0.accessibilityLabel == "Share" })
        #expect(idle.accessibilityTraits.contains(.notEnabled), "share is live with nothing chosen")
        let idleDelete = try #require(none.first { $0.accessibilityLabel == "Delete" })
        #expect(
            idleDelete.accessibilityTraits.contains(.notEnabled),
            "delete is live with nothing chosen")
    }

    /// MEMNG-589: while a delete run is out, neither button takes a tap — a second run would be
    /// refused by the store, and a share would fetch files the run is removing.
    @Test("the select toolbar takes no tap while a delete runs")
    func selectToolbarWhileDeleting() async throws {
        let found = try await Self.elements(
            of: LibrarySelectToolbar(
                count: 2, ownCount: 2, isSharing: false, isDeleting: true, share: {},
                delete: {}),
            waitFor: "2 Items Selected")
        let share = try #require(found.first { $0.accessibilityLabel == "Share" })
        let delete = try #require(found.first { $0.accessibilityLabel == "Delete" })
        #expect(share.accessibilityTraits.contains(.notEnabled), "share is live during a delete")
        #expect(delete.accessibilityTraits.contains(.notEnabled), "a second delete is offered")
    }

    /// MEMNG-684: a selection of only other members' pictures can be shared but not deleted —
    /// none of it is mine to delete.
    @Test("the select toolbar offers share but not delete over none of my pictures")
    func selectToolbarOverOthersPictures() async throws {
        let found = try await Self.elements(
            of: LibrarySelectToolbar(
                count: 2, ownCount: 0, isSharing: false, isDeleting: false, share: {},
                delete: {}),
            waitFor: "2 Items Selected")
        let share = try #require(found.first { $0.accessibilityLabel == "Share" })
        let delete = try #require(found.first { $0.accessibilityLabel == "Delete" })
        #expect(!share.accessibilityTraits.contains(.notEnabled), "share is inert")
        #expect(delete.accessibilityTraits.contains(.notEnabled), "delete offered for none of mine")
    }

    // MARK: - MEMNG-597: day groups and the date pill (plan page 3929 decision 13)

    /// A day of `count` square pictures taken at `instant`, uids `<prefix>-0…`.
    private static func day(_ prefix: String, _ count: Int, at instant: Date) -> [LibraryRow] {
        (0..<count).map {
            row(
                MediaViewerPageTests.image("\(prefix)-\($0)", width: 1000, height: 1000),
                takenAt: instant)
        }
    }

    private static func noon(_ day: Int) -> Date {
        // 2026-09-<day> 12:00Z; 2026-09-14 is a Monday.
        Date(timeIntervalSince1970: 1_789_387_200 + Double(day - 14) * 86_400)
    }

    /// On the test host's own scene, as the landing test explains.
    private static func show(_ harness: Harness) -> UIWindow {
        let frame = CGRect(origin: .zero, size: CGSize(width: 390, height: 844))
        let window: UIWindow
        if let scene = UIApplication.shared.connectedScenes.first(where: { $0 is UIWindowScene })
            as? UIWindowScene
        {
            window = UIWindow(windowScene: scene)
            window.frame = frame
        } else {
            window = UIWindow(frame: frame)
        }
        window.rootViewController = UIHostingController(rootView: harness)
        window.makeKeyAndVisible()
        return window
    }

    private static func element(_ label: String, in window: UIWindow) -> NSObject? {
        var found: [NSObject] = []
        collectElements(window, into: &found)
        return found.first { $0.accessibilityLabel == label }
    }

    /// The first scroll view in the hierarchy, and the line under its top inset in window points.
    private static func visibleTop(in root: UIView) -> (scroll: UIScrollView, top: CGFloat)? {
        var stack: [UIView] = [root]
        while let view = stack.popLast() {
            if let scroll = view as? UIScrollView {
                // A scroll view's bounds origin IS its content offset, so this point is the line
                // under the top inset, in the scroll's own coordinates.
                let line = CGPoint(
                    x: 0, y: scroll.contentOffset.y + scroll.adjustedContentInset.top)
                return (scroll, scroll.convert(line, to: nil).y)
            }
            stack.append(contentsOf: view.subviews)
        }
        return nil
    }

    @Test("a day heading reads its weekday, its date and the whole day's count")
    func dayHeadingReadsWeekdayDateCount() async throws {
        let items = Self.day("mon", 3, at: Self.noon(14))
        let bucket = LibraryBucket(
            key: "2026-09-14", count: 12, coverUID: "mon-0", coverThumbnailURL: nil)
        let window = Self.show(Harness(items: items, dayBuckets: [bucket]))
        let bare = Self.show(Harness(items: items))
        defer {
            window.isHidden = true
            bare.isHidden = true
        }
        var heading: NSObject?
        var unread: NSObject?
        for _ in 0..<60 where heading == nil || unread == nil {
            try await Task.sleep(for: .milliseconds(50))
            window.layoutIfNeeded()
            bare.layoutIfNeeded()
            heading = Self.element("Mon 14 Sep", in: window)
            unread = Self.element("Mon 14 Sep", in: bare)
        }
        let row = try #require(heading, "no day heading reads Mon 14 Sep")
        #expect(row.accessibilityTraits.contains(.header), "the day heading is not a heading")
        // The bucket's 12, not the 3 of the day that are loaded.
        #expect(row.accessibilityValue == "12 items")
        let pending = try #require(unread, "no day heading without buckets")
        #expect((pending.accessibilityValue ?? "").isEmpty, "a count drawn with no bucket read")
    }

    /// MEMNG-587's jump lands on the day's HEADING under the month header, not its first tile.
    @Test("a jump lands the day's heading at the top of the screen")
    func jumpLandsOnTheDayHeading() async throws {
        let items =
            Self.day("sun", 6, at: Self.noon(20)) + Self.day("mon", 4, at: Self.noon(14))
            + Self.day("old", 30, at: Self.noon(13))
        let landing = LibraryLanding(day: "2026-09-14", rowID: "mon-0", serial: 1)
        let consumed = LockedLandings()
        let window = Self.show(
            Harness(items: items, landing: landing, landed: { consumed.append($0) }))
        defer { window.isHidden = true }

        var gap: CGFloat = .infinity
        var offset: CGFloat = 0
        var settledPasses = 0
        for _ in 0..<80 where settledPasses < 5 {
            try await Task.sleep(for: .milliseconds(50))
            window.layoutIfNeeded()
            guard let heading = Self.element("Mon 14 Sep", in: window),
                let visible = Self.visibleTop(in: window)
            else { continue }
            gap = heading.accessibilityFrame.minY - visible.top
            offset = visible.scroll.contentOffset.y
            if abs(gap) <= 2, !consumed.all.isEmpty { settledPasses += 1 }
        }
        #expect(
            abs(gap) <= 2,
            "the heading sits \(gap)pt from the top of the screen (offset \(offset))"
        )
        #expect(consumed.all == [landing], "the landing was not reported scrolled to exactly once")
    }

    /// The list a landing held its heading in, and a move that is not the reader's hand.
    private struct HeldLanding {
        let window: UIWindow
        let host: UIHostingController<Harness>
        let items: [LibraryRow]

        /// Every pass after a move: where the heading stands against the top of the screen.
        func gaps(after passes: Int) async throws -> [CGFloat] {
            var seen: [CGFloat] = []
            for _ in 0..<passes {
                try await Task.sleep(for: .milliseconds(50))
                window.layoutIfNeeded()
                guard let heading = MediaLibraryRenderTests.element("Mon 14 Sep", in: window),
                    let visible = MediaLibraryRenderTests.visibleTop(in: window)
                else { continue }
                seen.append(heading.accessibilityFrame.minY - visible.top)
            }
            return seen
        }

        /// Straight back to the top of the page, as no finger would: the geometry path alone.
        func toTop() throws {
            let scroll = try #require(MediaLibraryRenderTests.visibleTop(in: window)?.scroll)
            scroll.setContentOffset(
                CGPoint(x: 0, y: -scroll.adjustedContentInset.top), animated: false)
        }
    }

    /// Hosts a grid landed on Mon 14 Sep under `generation`, and waits until the landing holds.
    private static func landAndHold(_ generation: GenerationBox) async throws -> HeldLanding {
        let items =
            Self.day("sun", 6, at: Self.noon(20)) + Self.day("mon", 4, at: Self.noon(14))
            + Self.day("old", 30, at: Self.noon(13))
        let landing = LibraryLanding(day: "2026-09-14", rowID: "mon-0", serial: 1)
        let consumed = LockedLandings()
        let window = Self.show(
            Harness(
                items: items, landing: landing, landed: { consumed.append($0) },
                generation: generation))
        let host = try #require(window.rootViewController as? UIHostingController<Harness>)
        let held = HeldLanding(window: window, host: host, items: items)
        var landed = false
        for _ in 0..<80 where !landed {
            let gap = try await held.gaps(after: 1).last ?? .infinity
            landed = abs(gap) <= 2 && !consumed.all.isEmpty
        }
        try #require(landed, "control: the landing never reached its heading")
        return held
    }

    /// A landing's heading is held at the line against the lazy stack's re-measuring, and only for
    /// the list it landed in: a filter, tag or order change is another list, and a move the reader
    /// did not make must not pull that list back to the old heading. A next page of the SAME list
    /// keeps the hold (the control).
    @Test("a landing's hold lasts through the list's next page and ends with the list")
    func holdEndsWithTheList() async throws {
        let held = try await Self.landAndHold(GenerationBox(1))
        defer { held.window.isHidden = true }

        // The same list's next page: the hold stands, and pulls the heading back.
        let paged = held.items + Self.day("older", 6, at: Self.noon(12))
        held.host.rootView = Harness(items: paged, generation: GenerationBox(1))
        try held.toTop()
        let kept = try await held.gaps(after: 12)
        #expect(
            kept.last.map { abs($0) <= 2 } == true,
            "control: a next page let go of the landing's heading (gaps \(kept))")

        // Another list holding the same day — a filter, tag or order change: the hold is gone.
        held.host.rootView = Harness(items: paged, generation: GenerationBox(2))
        try held.toTop()
        let after = try await held.gaps(after: 12)
        #expect(
            after.allSatisfy { $0 > 100 },
            "another list was pulled back to the old landing's heading (gaps \(after))")
    }

    /// The store's generation is asked where the hold would scroll, not remembered from the last
    /// time the grid was drawn: a list replaced between that drawing and a geometry callback
    /// already on its way must not be scrolled back to the old heading.
    @Test("a hold asks the live list generation at the scroll, not the one it was drawn with")
    func holdAsksTheLiveGeneration() async throws {
        let generation = GenerationBox(1)
        let held = try await Self.landAndHold(generation)
        defer { held.window.isHidden = true }

        // The control: with the generation unchanged, the geometry path pulls the heading back.
        try held.toTop()
        let kept = try await held.gaps(after: 12)
        #expect(
            kept.last.map { abs($0) <= 2 } == true,
            "control: the hold did not pull the heading back (gaps \(kept))")

        // The store moves on and nothing draws the grid again before the next geometry change.
        generation.value = 2
        try held.toTop()
        let after = try await held.gaps(after: 12)
        #expect(
            after.allSatisfy { $0 > 100 },
            "a replaced list was pulled back to the old landing's heading (gaps \(after))")
    }

    @Test("the date pill names the day at the top after a scroll, fades, and opens its month")
    func datePillNamesTheTopDay() async throws {
        let items = [20, 19, 18, 17, 16].flatMap { Self.day("d\($0)", 6, at: Self.noon($0)) }
        let months = LockedMonths()
        let window = Self.show(Harness(items: items, showMonth: { months.append($0) }))
        defer { window.isHidden = true }
        let target = "Thu 17 Sep"
        let pillLabel = "Thu · 17 Sep 2026"

        // Scroll down until the target heading is built, then put it 10 pt above the line.
        var placed = false
        for _ in 0..<80 where !placed {
            try await Task.sleep(for: .milliseconds(50))
            window.layoutIfNeeded()
            guard let visible = Self.visibleTop(in: window) else { continue }
            let (scroll, top) = visible
            if Self.element(pillLabel, in: window) == nil, scroll.contentOffset.y <= 0 {
                // The control: at the top of the page no pill shows.
                #expect(Self.element("Sun · 20 Sep 2026", in: window) == nil)
            }
            if let heading = Self.element(target, in: window),
                heading.accessibilityFrame.minY < top + 400
            {
                let delta = heading.accessibilityFrame.minY - top + 10
                scroll.setContentOffset(
                    CGPoint(x: 0, y: scroll.contentOffset.y + delta), animated: false)
                placed = true
            } else {
                scroll.setContentOffset(
                    CGPoint(x: 0, y: scroll.contentOffset.y + 300), animated: false)
            }
        }
        #expect(placed, "the target heading was never built")
        var pill: NSObject?
        for _ in 0..<20 where pill == nil {
            try await Task.sleep(for: .milliseconds(50))
            window.layoutIfNeeded()
            pill = Self.element(pillLabel, in: window)
        }
        let shown = try #require(pill, "no pill names \(pillLabel) after the scroll")
        #expect(shown.accessibilityActivate(), "the pill took no tap")
        #expect(months.all == ["2026-09"], "the pill's tap asked for \(months.all)")

        // One second after the scrolling stopped, it fades.
        var gone = false
        for _ in 0..<60 where !gone {
            try await Task.sleep(for: .milliseconds(50))
            window.layoutIfNeeded()
            gone = Self.element(pillLabel, in: window) == nil
        }
        #expect(gone, "the pill never faded")
    }

    /// Every element the hosted hierarchy reads out, in the order it offers them.
    private static func collectElements(_ node: Any, into found: inout [NSObject]) {
        guard let object = node as? NSObject else { return }
        if let label = object.accessibilityLabel, !label.isEmpty { found.append(object) }
        for child in object.accessibilityElements ?? [] { collectElements(child, into: &found) }
        if let view = object as? UIView {
            for subview in view.subviews { collectElements(subview, into: &found) }
        }
    }

    /// Every label the hosted hierarchy reads out, in the order it offers them — the walk
    /// `LayoutProbe.reads` makes, collecting rather than searching.
    private static func collectLabels(_ node: Any, into found: inout [String]) {
        guard let object = node as? NSObject else { return }
        if let label = object.accessibilityLabel, !label.isEmpty { found.append(label) }
        for child in object.accessibilityElements ?? [] { collectLabels(child, into: &found) }
        if let view = object as? UIView {
            for subview in view.subviews { collectLabels(subview, into: &found) }
        }
    }

    /// How far the grid's scroll has been brought down, and the furthest it can be.
    private static func scrollOffset(in root: UIView) -> (offset: CGFloat, bottom: CGFloat) {
        var stack: [UIView] = [root]
        while let view = stack.popLast() {
            if let scroll = view as? UIScrollView {
                let bottom =
                    scroll.contentSize.height + scroll.adjustedContentInset.bottom
                    - scroll.bounds.height
                return (scroll.contentOffset.y, bottom)
            }
            stack.append(contentsOf: view.subviews)
        }
        return (0, .infinity)
    }

    /// The tallest scrollable content in the hierarchy — SwiftUI's `ScrollView` bridges to a
    /// `UIScrollView`, whose `contentSize` is what the grid actually laid out.
    private static func scrollContentHeight(in root: UIView) -> CGFloat {
        var stack: [UIView] = [root]
        var best: CGFloat = 0
        while let view = stack.popLast() {
            if let scroll = view as? UIScrollView {
                best = max(best, scroll.contentSize.height)
            }
            stack.append(contentsOf: view.subviews)
        }
        return best
    }
}

/// The landings a hosted grid reported scrolled to, in order.
@MainActor
private final class LockedLandings {
    private(set) var all: [LibraryLanding] = []
    func append(_ landing: LibraryLanding) { all.append(landing) }
}

/// A list generation a test moves behind the grid's back, the way the store's moves.
@MainActor
private final class GenerationBox {
    var value: Int
    init(_ value: Int) { self.value = value }
}

/// The months a hosted grid's date pill asked for, in order.
@MainActor
private final class LockedMonths {
    private(set) var all: [String] = []
    func append(_ month: String) { all.append(month) }
}
