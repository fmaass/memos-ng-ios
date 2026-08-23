import MemosCore
import SwiftUI

/// Sign-in v1: a server address and a personal access token pasted from the web app.
///
/// The token is validated against `GET /api/auth/user` before it is stored, so a typo fails here
/// rather than as an empty timeline later.
public struct SignInView: View {
    @Environment(SessionStore.self) private var session
    @State private var serverAddress = ""
    @State private var token = ""
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
                    SecureField("memos_pat_…", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .token)
                } header: {
                    Text("Access token")
                } footer: {
                    Text("Create a personal access token in the memos web app, then paste it here.")
                }
                if let error = session.lastError {
                    Section {
                        Text(error).foregroundStyle(.red)
                    }
                }
                Section {
                    Button {
                        Task { await session.signIn(serverAddress: serverAddress, token: token) }
                    } label: {
                        if isSigningIn {
                            ProgressView()
                        } else {
                            Text("Sign in")
                        }
                    }
                    .disabled(serverAddress.isEmpty || token.isEmpty || isSigningIn)
                }
            }
            .navigationTitle("Memos")
        }
    }
}
