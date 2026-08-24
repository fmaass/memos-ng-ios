import MemosCore
import SwiftUI

/// Sign-in: the household account first, a pasted token as the explicit fallback.
///
/// The native flow is the door most people should walk through — one tap, the family sign-on
/// they already have, no copied secrets. The token form stays because it is the reviewer's and
/// tinkerer's path, and because a fallback that exists is one that can be tested.
public struct SignInView: View {
    @Environment(SessionStore.self) private var session
    @State private var serverAddress = "memos.discomarder.live"
    @State private var token = ""
    @State private var showTokenForm = false
    @FocusState private var focus: Field?

    private enum Field: Hashable {
        case server
        case token
    }

    public init() {}

    private var isSigningIn: Bool { session.state == .signingIn }

    public var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("memos.example.com", text: $serverAddress)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .focused($focus, equals: .server)
                }
                Section {
                    Button {
                        Task {
                            await session.signInNatively(
                                serverAddress: serverAddress,
                                deviceName: UIDevice.current.name,
                                presenter: WebAuthenticationLoginPresenter()
                            )
                        }
                    } label: {
                        if isSigningIn {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            Label(
                                "Sign in with the household account",
                                systemImage: "person.badge.key"
                            )
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(serverAddress.isEmpty || isSigningIn)
                } footer: {
                    Text("Opens the family sign-on. This app never sees the password.")
                }
                if let error = session.lastError {
                    Section {
                        Text(error).foregroundStyle(.red)
                    }
                }
                Section {
                    DisclosureGroup("Advanced: sign in with a token", isExpanded: $showTokenForm) {
                        SecureField("memos_pat_…", text: $token)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($focus, equals: .token)
                        Button {
                            Task {
                                await session.signIn(serverAddress: serverAddress, token: token)
                            }
                        } label: {
                            if isSigningIn {
                                ProgressView()
                            } else {
                                Text("Sign in with this token")
                            }
                        }
                        .disabled(serverAddress.isEmpty || token.isEmpty || isSigningIn)
                    }
                } footer: {
                    Text("Create a personal access token in the memos web app, then paste it here.")
                }
            }
            .navigationTitle("Memos")
        }
    }
}
