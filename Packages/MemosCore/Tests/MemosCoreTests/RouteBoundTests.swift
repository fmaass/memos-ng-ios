import Foundation
import MemosAPI
import Testing

@testable import MemosCore

/// What a fetch is allowed to wait for, read off the configuration the app really builds.
///
/// The numbers are the ones a measurement bought, not a preference: against a destination that is
/// routed and never answers, a request on the framework's defaults took the full 60 s to fail with
/// `URLError.timedOut` — on the media session and on the generated client's alike. A photograph
/// nobody can fetch is worth its triangle in seconds.
@Suite("The bound on a fetch that is never answered")
struct RouteBoundTests {
    @Test("the media session gives up on a fetch nothing is answering")
    func theMediaSessionIsBounded() {
        let configuration = MediaCache.makeSessionConfiguration(
            cache: URLCache(memoryCapacity: 0, diskCapacity: 0)
        )

        #expect(configuration.timeoutIntervalForRequest == 15)
    }

    /// The generated client's session, which is the app's own and not `URLSession.shared`: a
    /// shared session copies its configuration when it is made and never reads it again, and the
    /// requests are built inside the transport, so this is where the bound is stated.
    @Test("the generated client's session gives up on a request nothing is answering")
    func theAPISessionIsBounded() {
        let configuration = APIClientFactory.urlSession.configuration

        #expect(configuration.timeoutIntervalForRequest == 15)
    }
}
