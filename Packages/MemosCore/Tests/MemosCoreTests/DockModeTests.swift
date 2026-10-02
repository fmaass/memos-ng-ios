import MemosCore
import Testing

/// The Library's two bottom bars, every event from both states (MEMNG-604). Each row is written
/// out rather than derived, so the table is the rule as the owner gave it, not the code read back:
/// 3 x 3 presses, the icon and 3 selections are 13 events, and 6 + 12 + 2 + 6 rows cover each
/// from both states. There is no scroll event, so no scroll can change the state.
@Suite("DockMode")
struct DockModeTests {
    private struct Row: CustomStringConvertible {
        let from: DockMode
        let event: DockEvent
        let to: DockMode
        var description: String { "\(from) + \(event) -> \(to)" }
    }

    private func check(_ rows: [Row]) {
        for row in rows {
            #expect(row.from.after(row.event) == row.to, "\(row)")
        }
    }

    @Test("the app opens on the tabs")
    func opensOnTheTabs() {
        #expect(DockMode.initial == .tabs)
    }

    @Test("a press on the Library's item gives the scope toolbar, from any tab and either state")
    func libraryPressGivesTheScope() {
        check([
            Row(from: .tabs, event: .pressedTab(.library, showing: .library), to: .scope),
            Row(from: .scope, event: .pressedTab(.library, showing: .library), to: .scope),
            Row(from: .tabs, event: .pressedTab(.library, showing: .timeline), to: .scope),
            Row(from: .scope, event: .pressedTab(.library, showing: .timeline), to: .scope),
            Row(from: .tabs, event: .pressedTab(.library, showing: .places), to: .scope),
            Row(from: .scope, event: .pressedTab(.library, showing: .places), to: .scope),
        ])
    }

    @Test("a press on Timeline or Places gives the tabs, whatever was showing")
    func otherPressGivesTheTabs() {
        check([
            Row(from: .tabs, event: .pressedTab(.timeline, showing: .library), to: .tabs),
            Row(from: .scope, event: .pressedTab(.timeline, showing: .library), to: .tabs),
            Row(from: .tabs, event: .pressedTab(.timeline, showing: .timeline), to: .tabs),
            Row(from: .scope, event: .pressedTab(.timeline, showing: .timeline), to: .tabs),
            Row(from: .tabs, event: .pressedTab(.timeline, showing: .places), to: .tabs),
            Row(from: .scope, event: .pressedTab(.timeline, showing: .places), to: .tabs),
            Row(from: .tabs, event: .pressedTab(.places, showing: .library), to: .tabs),
            Row(from: .scope, event: .pressedTab(.places, showing: .library), to: .tabs),
            Row(from: .tabs, event: .pressedTab(.places, showing: .timeline), to: .tabs),
            Row(from: .scope, event: .pressedTab(.places, showing: .timeline), to: .tabs),
            Row(from: .tabs, event: .pressedTab(.places, showing: .places), to: .tabs),
            Row(from: .scope, event: .pressedTab(.places, showing: .places), to: .tabs),
        ])
    }

    @Test("the Library icon in the scope toolbar gives the tabs back")
    func iconGivesTheTabs() {
        check([
            Row(from: .scope, event: .pressedLibraryIcon, to: .tabs),
            Row(from: .tabs, event: .pressedLibraryIcon, to: .tabs),
        ])
    }

    @Test("arriving on the Library keeps the state; arriving anywhere else is the tabs")
    func selectionLeavesTheLibrary() {
        check([
            Row(from: .tabs, event: .selected(.library), to: .tabs),
            Row(from: .scope, event: .selected(.library), to: .scope),
            Row(from: .tabs, event: .selected(.timeline), to: .tabs),
            Row(from: .scope, event: .selected(.timeline), to: .tabs),
            Row(from: .tabs, event: .selected(.places), to: .tabs),
            Row(from: .scope, event: .selected(.places), to: .tabs),
        ])
    }
}
