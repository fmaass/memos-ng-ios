import Foundation
import Testing

@testable import MemosCore

/// The rule every credential decision in the vault is taken by, exhausted rather than argued:
/// **no lower-precedence credential may become authoritative unless every higher-precedence
/// namespace has been proven ABSENT** — and absent means the namespace answered "nothing here",
/// never that it failed to answer.
///
/// It is a pure function so that this can be a property test over every answer the namespaces can
/// give, rather than a handful of cases somebody thought of.
@Suite("Credential precedence")
struct CredentialPrecedenceTests {
    /// Every combination of answers four namespaces can give: three outcomes, four positions,
    /// eighty-one rows. The values are distinct per position so a promotion can be traced to the
    /// namespace it came from.
    private func combinations(width: Int) -> [[CredentialReadOutcome]] {
        var rows: [[CredentialReadOutcome]] = [[]]
        for position in 0..<width {
            rows = rows.flatMap { row in
                [row + [.absent], row + [.unreadable], row + [.value("value-\(position)")]]
            }
        }
        return rows
    }

    @Test("no answer below a namespace that would not answer is ever promoted")
    func unreadableAboveBlocksEverythingBelow() {
        let rows = combinations(width: 4)
        #expect(rows.count == 81)

        for row in rows {
            let firstUnreadable = row.firstIndex(of: .unreadable)
            let firstValue = row.firstIndex {
                if case .value = $0 { return true }
                return false
            }

            switch CredentialPrecedence.decide(row) {
            case .authoritative(let index, let value):
                #expect(row[index] == .value(value), "\(row)")
                #expect(row.prefix(index).allSatisfy { $0 == .absent }, "\(row)")
                // The whole invariant, in one line: a namespace that would not answer, anywhere
                // above this one, makes this one unpromotable.
                #expect(firstUnreadable == nil || firstUnreadable! > index, "\(row)")
            case .blocked(let index):
                #expect(row[index] == .unreadable, "\(row)")
                #expect(row.prefix(index).allSatisfy { $0 == .absent }, "\(row)")
                #expect(firstValue == nil || firstValue! > index, "\(row)")
            case .absent:
                #expect(row.allSatisfy { $0 == .absent }, "\(row)")
            }
        }
    }

    @Test("a newer namespace that would not answer is not stepped over for an older one")
    func anUnreadableNewestNamespaceBlocks() {
        #expect(
            CredentialPrecedence.decide([.absent, .unreadable, .value("older")])
                == .blocked(index: 1)
        )
    }

    @Test("absence is concluded only when every namespace said so")
    func absenceNeedsEveryAnswer() {
        #expect(CredentialPrecedence.decide([.absent, .absent, .absent]) == .absent)
        #expect(CredentialPrecedence.decide([.absent, .unreadable, .absent]) == .blocked(index: 1))
        #expect(CredentialPrecedence.decide([]) == .absent)
    }

    @Test("the highest value wins, whatever is below it")
    func theHighestValueWins() {
        #expect(
            CredentialPrecedence.decide([.absent, .value("newer"), .value("older")])
                == .authoritative(index: 1, value: "newer")
        )
        #expect(
            CredentialPrecedence.decide([.value("home"), .unreadable])
                == .authoritative(index: 0, value: "home")
        )
    }

    @Test("a read that answered nothing is absence, and a read that threw is not")
    func outcomesReadFromAnAnswer() {
        #expect(CredentialReadOutcome(nil) == .absent)
        #expect(CredentialReadOutcome("memos_pat") == .value("memos_pat"))
    }
}
