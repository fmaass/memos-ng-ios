import Foundation
import SwiftUI
import Testing
import UIKit

@testable import MemosFeatures

/// The modifier the three tab roots hang their reload on, driven the way the session drives it.
///
/// Hosted in a real key window rather than measured, because what is under test is a reaction to a
/// value changing WHILE the screen is up: a view that is never laid out never reacts at all, and a
/// modifier that fired on first appearance would look identical to one that worked if the counter
/// were only ever read after the change.
@MainActor
@Suite("Reloading a screen when the server comes back")
struct ReloadsOnRecoveryTests {
    /// How many recoveries the session has seen, as a screen observes it.
    @Observable
    final class Recoveries {
        var count: Int

        init(_ count: Int) { self.count = count }
    }

    private struct Probe: View {
        let recoveries: Recoveries
        let reloads: Box<Int>

        var body: some View {
            Color.clear.reloadsOnRecovery(recoveries.count) { reloads.value += 1 }
        }
    }

    @Test("a screen appearing reloads nothing, a recovery reloads it once, and once only")
    func itFiresOnTheChangeAndNotOnAppearance() async {
        // Not zero: a screen opened after several recoveries must still reload nothing until the
        // next one, and a modifier keyed on the value rather than on the change would fire here.
        let recoveries = Recoveries(3)
        let reloads = Box(0)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        let host = UIHostingController(rootView: Probe(recoveries: recoveries, reloads: reloads))
        window.rootViewController = host
        window.makeKeyAndVisible()
        await settle(host)

        #expect(reloads.value == 0, "appearing reloaded the screen")

        recoveries.count = 4
        await settle(host)
        #expect(reloads.value == 1, "a recovery did not reload the screen")

        // The same number again is not a recovery, and SwiftUI hands a screen the same value more
        // than once for reasons of its own.
        recoveries.count = 4
        await settle(host)
        #expect(reloads.value == 1, "the screen reloaded again without a recovery")

        window.isHidden = true
        window.rootViewController = nil
    }

    /// Letting go of the main actor, rather than spinning the run loop while holding it.
    ///
    /// The reload is handed to a task, and that task is on the main actor too: a spin that never
    /// suspends leaves it queued behind the test itself, and the run loop cannot be spun from an
    /// asynchronous context at all. Laying out twice around the suspensions gives SwiftUI its own
    /// turn to notice the value before the task is waited for.
    private func settle(_ host: UIHostingController<some View>) async {
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        try? await Task.sleep(for: .milliseconds(100))
        host.view.layoutIfNeeded()
        try? await Task.sleep(for: .milliseconds(100))
    }
}
