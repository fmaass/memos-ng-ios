import Foundation
import Testing

@testable import MemosOutbox

/// MEMNG-958: the adaptive in-flight budget, as a pure value.
@Suite("Adaptive upload budget: 429s, generations and the published admission")
struct AdaptiveUploadBudgetTests {
    private let start = Date(timeIntervalSince1970: 1_750_000_000)

    @Test("three 429s in a row lower the budget to one; two do not")
    func threeRateLimitsLowerToOne() {
        var budget = AdaptiveUploadBudget()
        #expect(budget.ceiling(onWiFi: false, admission: nil, at: start) == 2)
        budget.record(rateLimited: true, issuedUnder: 0, at: start)
        budget.record(rateLimited: true, issuedUnder: 0, at: start)
        #expect(budget.ceiling(onWiFi: false, admission: nil, at: start) == 2)
        budget.record(rateLimited: true, issuedUnder: 0, at: start)
        #expect(budget.ceiling(onWiFi: false, admission: nil, at: start) == 1)
        let later = start.addingTimeInterval(600)
        #expect(budget.ceiling(onWiFi: true, admission: nil, at: later) == 1)
        // One answer that is not a 429 ends the run.
        budget.record(rateLimited: false, issuedUnder: 0, at: start)
        #expect(budget.ceiling(onWiFi: false, admission: nil, at: start) == 2)
    }

    @Test("a 429 of an older generation, arriving after the budget was raised, is ignored")
    func staleRateLimitIgnored() {
        var budget = AdaptiveUploadBudget()
        _ = budget.ceiling(onWiFi: false, admission: nil, at: start)
        for _ in 0..<3 { budget.record(rateLimited: true, issuedUnder: 0, at: start) }
        #expect(budget.ceiling(onWiFi: false, admission: nil, at: start) == 1)
        #expect(budget.generation == 0)
        budget.record(rateLimited: false, issuedUnder: 0, at: start)
        #expect(budget.ceiling(onWiFi: false, admission: nil, at: start) == 2)
        // The raise opened a new generation.
        #expect(budget.generation == 1)
        // The bodies the old budget had in flight answer late: none of them lowers it again.
        for _ in 0..<3 { budget.record(rateLimited: true, issuedUnder: 0, at: start) }
        #expect(budget.ceiling(onWiFi: false, admission: nil, at: start) == 2)
        // The same answers under the generation now current do.
        for _ in 0..<3 { budget.record(rateLimited: true, issuedUnder: 1, at: start) }
        #expect(budget.ceiling(onWiFi: false, admission: nil, at: start) == 1)
    }

    @Test("three on Wi-Fi only after a whole quiet minute, and a 429 starts the minute again")
    func wifiAfterQuietMinute() {
        var budget = AdaptiveUploadBudget()
        let at = { (seconds: TimeInterval) in self.start.addingTimeInterval(seconds) }
        #expect(budget.ceiling(onWiFi: true, admission: nil, at: at(0)) == 2)
        #expect(budget.ceiling(onWiFi: true, admission: nil, at: at(59)) == 2)
        #expect(budget.ceiling(onWiFi: true, admission: nil, at: at(60)) == 3)
        #expect(budget.ceiling(onWiFi: false, admission: nil, at: at(60)) == 2)
        budget.record(rateLimited: true, issuedUnder: budget.generation, at: at(70))
        #expect(budget.ceiling(onWiFi: true, admission: nil, at: at(129)) == 2)
        #expect(budget.ceiling(onWiFi: true, admission: nil, at: at(130)) == 3)
    }

    @Test("the ceiling is the published admission, whichever rule applies")
    func admissionIsTheCeiling() {
        var budget = AdaptiveUploadBudget()
        let quiet = start.addingTimeInterval(60)
        _ = budget.ceiling(onWiFi: true, admission: nil, at: start)
        #expect(budget.ceiling(onWiFi: true, admission: nil, at: quiet) == 3)
        #expect(budget.ceiling(onWiFi: true, admission: 2, at: quiet) == 2)
        #expect(budget.ceiling(onWiFi: false, admission: 1, at: quiet) == 1)
        // A larger admission never lifts the budget past its own rules.
        #expect(budget.ceiling(onWiFi: true, admission: 8, at: quiet) == 3)
        #expect(budget.ceiling(onWiFi: false, admission: 8, at: quiet) == 2)
        // An admission that is no number of bodies is no admission.
        #expect(budget.ceiling(onWiFi: false, admission: 0, at: quiet) == 2)
    }
}

/// MEMNG-958: a file the server turned away inside a batch, as the planner sees it.
@Suite("Whole lane: a file held alone")
struct HeldFilePlannerTests {
    private let now = Date(timeIntervalSince1970: 1_750_000_000)

    @Test("a held file is never sent; the capture holds once nothing else is left; release clears")
    func heldFileWaitsThenHolds() {
        var held = Fixture.file()
        held.heldReason = .tooLarge
        let sibling = Fixture.file()
        var job = Fixture.job(files: [held, sibling]).with { $0.transport = .whole }
        let plan = OutboxPlanner.nextWholeAction(
            for: job, credentials: Fixture.credentials(), now: now, schedulingOpen: true
        )
        #expect(plan == .upload(starting: [sibling.id]))
        job = job.updating(sibling.id) {
            $0.uploadUID = "u2"
            $0.bytesConfirmed = $0.byteSize
        }
        let after = OutboxPlanner.nextWholeAction(
            for: job, credentials: Fixture.credentials(), now: now, schedulingOpen: true
        )
        #expect(after == .hold(.tooLarge))
        let released = job.released(at: now)
        #expect(released.files.allSatisfy { $0.heldReason == nil })
        #expect(
            OutboxPlanner.nextWholeAction(
                for: released, credentials: Fixture.credentials(), now: now, schedulingOpen: true
            ) == .upload(starting: [held.id])
        )
    }
}

/// MEMNG-958: the sessions of a capture's files, opened by one batch request.
@Suite("Whole lane: the batch upload create")
struct UploadBatchEngineTests {
    private static func batches(_ rig: WholeRig) -> [URLRequest] {
        rig.http.requests(method: "POST").filter { $0.url?.path() == "/api/uploads/batch" }
    }

    private static func entries(_ request: URLRequest) throws -> [[String: Any]] {
        let body = try #require(request.httpBody)
        let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        return try #require(object["entries"] as? [[String: Any]])
    }

    @Test("one batch request carries every file's session; no single create is sent")
    func oneBatchCarriesEveryFile() async throws {
        let rig = try await WholeRig.make()
        defer { rig.cleanUp() }
        await rig.engine.drain()
        let batches = Self.batches(rig)
        #expect(batches.count == 1)
        let entries = try Self.entries(try #require(batches.first))
        #expect(entries.compactMap { $0["filename"] as? String } == ["picture.heic", "video.mov"])
        #expect(entries.compactMap { $0["size"] as? Int } == [1000, 3000])
        let singles = rig.http.requests(method: "POST").filter {
            $0.url?.path() == "/api/uploads"
        }
        #expect(singles.isEmpty)
        let saved = try await rig.reload()
        #expect(saved.files.allSatisfy { $0.uploadUID != nil })
        #expect(rig.session.createdTasks.count == 2)
    }

    @Test("a 413 for one entry holds only that file; its sibling is sent and lands")
    func entryRefusalHoldsOnlyThatFile() async throws {
        let rig = try await WholeRig.make(
            answerPost: { request in
                let body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                return body.contains("video.mov") ? OutboxHTTPResponse(statusCode: 413) : nil
            }
        )
        defer { rig.cleanUp() }
        await rig.engine.drain()
        #expect(Self.batches(rig).count == 1)
        let saved = try await rig.reload()
        #expect(saved.state != .held)
        #expect(saved.file(rig.video.id)?.heldReason == .tooLarge)
        #expect(saved.file(rig.video.id)?.uploadUID == nil)
        #expect(saved.file(rig.picture.id)?.heldReason == nil)
        #expect(saved.file(rig.picture.id)?.uploadUID != nil)
        // Only the picture was handed to the session.
        #expect(rig.session.createdTasks.count == 1)
        let pictureTask = try rig.task(for: rig.picture.id)
        await rig.engine.handle(try rig.answer(pictureTask, status: 200, received: 1000))
        // The picture landed; with only the refused file left, the capture holds for it, and no
        // memo is created without it.
        let landed = try await rig.eventually {
            await rig.repository.job(rig.job.id)?.state == .held
        }
        #expect(landed)
        let held = try await rig.reload()
        #expect(held.holdReason == .tooLarge)
        #expect(held.file(rig.picture.id)?.isComplete == true)
        #expect(rig.completion.idempotencyKeys.isEmpty)
        #expect(Self.batches(rig).count == 1)
    }
}
