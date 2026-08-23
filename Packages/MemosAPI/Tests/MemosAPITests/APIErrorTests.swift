import MemosAPI
import Testing

@Suite("APIError")
struct APIErrorTests {
    @Test("401 and 403 both mean the credential is gone")
    func mapsAuthFailures() {
        #expect(APIError.fromStatus(401) == .unauthorized)
        #expect(APIError.fromStatus(403) == .unauthorized)
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
