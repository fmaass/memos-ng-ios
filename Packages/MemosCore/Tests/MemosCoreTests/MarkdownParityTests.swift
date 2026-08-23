import Foundation
import MemosCore
import Testing

/// Locates the fixture inside the test bundle. Swift Testing has no test class to hand
/// `Bundle(for:)`, so this token supplies one.
private final class BundleToken {}

/// The parity gate.
///
/// Each case carries its own Markdown input, so this suite never needs the SPA running: it renders
/// the input through the app's own block model and asserts the projection memos-ng committed. A
/// renderer that flattens a list, loses a task's state, keeps a `javascript:` link tappable or
/// leaves `~~struck~~` unstyled cannot produce a matching projection.
@Suite("markdown parity with the SPA renderer")
struct MarkdownParityTests {
    static let fixture: MarkdownParityFixture = {
        let bundle = Bundle(for: BundleToken.self)
        guard let url = bundle.url(forResource: "markdown-parity", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let decoded = try? MarkdownParityFixture.decode(from: data)
        else {
            fatalError("markdown-parity.json is not in the test bundle — check project.yml")
        }
        return decoded
    }()

    @Test("the vendored fixture is schema 1 and has enough cases to be worth anything")
    func fixtureShape() {
        #expect(Self.fixture.schema == 1)
        #expect(Self.fixture.cases.count >= 15)
    }

    @Test("every case projects exactly as the SPA does", arguments: Self.fixture.cases)
    func projectionMatches(testCase: MarkdownParityFixture.Case) {
        let projected = MarkdownParity.project(testCase.markdown)
        #expect(projected == testCase.projection, "case \(testCase.id)")
    }
}

extension MarkdownParityFixture.Case: @retroactive CustomTestStringConvertible {
    public var testDescription: String { id }
}
