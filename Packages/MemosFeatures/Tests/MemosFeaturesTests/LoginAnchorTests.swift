import Foundation
import MemosCore
import Testing

@testable import MemosFeatures

/// The TestFlight build installed on a phone had a "Sign in" button that did nothing: the
/// authentication sheet never appeared, and nothing on the screen said why. The live
/// `ASWebAuthenticationSession` cannot be driven from a test — the tap that proves it is on a
/// device — so everything AROUND it is made deterministic here: which window the sheet is put on,
/// and what happens when there is no such window.
@Suite("Which window the sign-in sheet is put on")
struct LoginAnchorTests {
    private func scene(
        _ activation: LoginAnchor.Activation,
        _ windows: [Bool] = [false]
    ) -> LoginAnchor.SceneState {
        LoginAnchor.SceneState(activation: activation, windowIsKey: windows)
    }

    @Test("the key window of the scene in front")
    func keyWindowOfTheActiveScene() {
        let scenes = [
            scene(.background, [true]),
            scene(.foregroundActive, [false, true, false]),
        ]
        #expect(LoginAnchor.choice(among: scenes) == .window(scene: 1, window: 1))
    }

    @Test("a scene in front with no key window still has a window")
    func firstWindowWhenNoneIsKey() {
        #expect(
            LoginAnchor.choice(among: [scene(.foregroundActive, [false, false])])
                == .window(scene: 0, window: 0)
        )
    }

    @Test("active beats inactive, whatever order the set came out in")
    func activeOutranksInactive() {
        let scenes = [scene(.foregroundInactive, [true]), scene(.foregroundActive, [true])]
        #expect(LoginAnchor.choice(among: scenes) == .window(scene: 1, window: 0))
    }

    @Test("an inactive scene is still on screen when nothing is active")
    func inactiveIsUsedWhenNothingIsActive() {
        let scenes = [scene(.background, [true]), scene(.foregroundInactive, [false, true])]
        #expect(LoginAnchor.choice(among: scenes) == .window(scene: 1, window: 1))
    }

    @Test("a scene in front with no windows at all is passed over, not indexed into")
    func windowlessSceneIsSkipped() {
        let scenes = [scene(.foregroundActive, []), scene(.foregroundInactive, [true])]
        #expect(LoginAnchor.choice(among: scenes) == .window(scene: 1, window: 0))
    }

    /// The one that matters. A window belonging to a background or unattached scene is not on
    /// screen, and a scene-less `UIWindow()` — deprecated in iOS 26 for this exact reason — is
    /// attached to nothing at all. Presenting on either is what a dead button is made of, so the
    /// decision refuses rather than inventing an anchor.
    @Test("nothing on screen is an explicit refusal, never a detached window")
    func offscreenScenesAreNotPresentedOn() {
        let scenes = [
            scene(.background, [true, false]),
            scene(.unattached, [true]),
        ]
        #expect(LoginAnchor.choice(among: scenes) == .nowhereToPresent)
    }

    @Test("no connected scene at all is the same refusal")
    func noScenesAtAll() {
        #expect(LoginAnchor.choice(among: []) == .nowhereToPresent)
    }
}

/// The other half: the refusal has to become something the person holding the phone can read.
@Suite("A sign-in that cannot be presented says so")
struct WebAuthenticationLoginPresenterTests {
    @Test("with nowhere to present, it fails before starting a session")
    func noAnchorFailsBeforeStarting() async throws {
        let presenter = WebAuthenticationLoginPresenter(anchor: { nil })
        let authorizeURL = try #require(URL(string: "https://memos.example.com/api/auth/login"))

        await #expect(throws: NativeLoginError.self) {
            _ = try await presenter.authenticate(
                authorizeURL: authorizeURL,
                callbackHost: "memos.example.com",
                callbackPath: "/ios/auth/callback"
            )
        }
    }

    /// A thrown error with nothing to say is the dead button in another costume: `SignInView`
    /// renders `SessionStore.lastError`, which is this `message` and nothing else.
    @Test("the failure carries a sentence the sign-in screen can show")
    func theFailureReachesTheScreen() async throws {
        let presenter = WebAuthenticationLoginPresenter(anchor: { nil })
        let authorizeURL = try #require(URL(string: "https://memos.example.com/api/auth/login"))

        do {
            _ = try await presenter.authenticate(
                authorizeURL: authorizeURL,
                callbackHost: "memos.example.com",
                callbackPath: "/ios/auth/callback"
            )
            Issue.record("a presenter with no window to use resolved a sign-in")
        } catch let error as NativeLoginError {
            guard case .presentationFailed(let detail) = error else {
                Issue.record("expected a presentation failure, got \(error)")
                return
            }
            #expect(!detail.isEmpty, "a failure with no detail cannot be acted on")
            #expect(error.message?.isEmpty == false, "cancelled is the only silent outcome")
        }
    }
}
