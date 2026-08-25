/// Which window the sign-in is put on — decided on a description of the app's scenes rather than
/// on the scenes themselves, so the decision can be tested.
///
/// `UIApplication.connectedScenes` is a SET: it has no order, so "the first one" is not the one in
/// front. Getting this wrong is invisible on a simulator with a single scene and a real bug on a
/// device that has more than one — the browser view is presented somewhere nobody is looking,
/// which from the outside is indistinguishable from a button that did nothing.
///
/// There is deliberately no last resort here. A window that belongs to no scene is not a place to
/// present from: `UIWindow.init()` and `init(frame:)` are deprecated as of iOS 26 ("Use
/// init(windowScene:) instead") precisely because such a window is attached to nothing, and it has
/// no view controller to present from either. Handing one back turns a diagnosable failure into a
/// view that never appears, so "nowhere to present" is a value the caller has to handle.
enum LoginAnchor {
    /// A window scene as the decision sees it: what state it is in, and which of its windows is
    /// key. Nothing about UIKit survives into the decision itself.
    struct SceneState: Equatable, Sendable {
        /// Mirrors `UIScene.ActivationState`, so the mapping happens once at the boundary.
        let activation: Activation
        /// One entry per window of the scene, in the scene's own order; `true` for the key window.
        let windowIsKey: [Bool]

        init(activation: Activation, windowIsKey: [Bool]) {
            self.activation = activation
            self.windowIsKey = windowIsKey
        }
    }

    enum Activation: Equatable, Sendable {
        case foregroundActive
        case foregroundInactive
        case background
        case unattached
    }

    /// Where the sign-in goes, as indices back into the list that was described.
    enum Choice: Equatable, Sendable {
        case window(scene: Int, window: Int)
        /// No connected scene is on screen with a window to present on. An explicit outcome, not
        /// a fallback: the caller reports it instead of starting a session that cannot appear.
        case nowhereToPresent
    }

    /// The scene the person is actually looking at, and the window on it that owns the screen.
    ///
    /// Foreground-active scenes are considered before foreground-inactive ones (an app returning
    /// from the app switcher or sitting under Control Center is inactive, and its window is still
    /// the one on screen). Background and unattached scenes are not considered at all: their
    /// windows are not visible, and presenting on one is the failure this function exists to
    /// prevent.
    ///
    /// The caller turns the answer into the view controller it presents from — this decides the
    /// window, and nothing above it.
    static func choice(among scenes: [SceneState]) -> Choice {
        let order: [Activation] = [.foregroundActive, .foregroundInactive]
        for activation in order {
            for (index, scene) in scenes.enumerated() where scene.activation == activation {
                // The key window if the scene names one, and otherwise its first — a scene on
                // screen with no key window still has a window the sign-in can sit on.
                guard let window = scene.windowIsKey.firstIndex(of: true) ?? scene.firstWindow
                else { continue }
                return .window(scene: index, window: window)
            }
        }
        return .nowhereToPresent
    }
}

extension LoginAnchor.SceneState {
    /// `0` when the scene has any window at all. A scene with none is skipped rather than chosen:
    /// indexing its (empty) window list is what a crash is made of.
    fileprivate var firstWindow: Int? { windowIsKey.isEmpty ? nil : 0 }
}
