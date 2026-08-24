import MemosAPI
import Testing

@Suite("APIError")
struct APIErrorTests {
    @Test("401 ends the session; 403 is someone else's memo, not a dead credential")
    func mapsAuthFailures() {
        #expect(APIError.fromStatus(401) == .unauthorized)
        #expect(APIError.fromStatus(403) == .forbidden)
    }

    @Test("404 is distinct from a server fault")
    func mapsNotFound() {
        #expect(APIError.fromStatus(404) == .notFound)
    }

    @Test("anything else keeps its status")
    func mapsServerFaults() {
        #expect(APIError.fromStatus(500) == .server(status: 500))
        #expect(APIError.fromStatus(418) == .server(status: 418))
    }
}
