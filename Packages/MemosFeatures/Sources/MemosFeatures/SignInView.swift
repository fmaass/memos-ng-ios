import MemosCore
import SwiftUI

/// Sign-in: the household account first, a pasted token as the explicit fallback.
///
/// It is the first screen anyone sees, and it used to be a settings form — a server field, then a
/// button, then a disclosure triangle, all weighted the same. It is a door now: the mark, the
/// name, and ONE button. The server address and the token path are still there, below, at the size
/// their rarity deserves.
///
/// The native flow is the door most people should walk through — one tap, the family sign-on they
/// already have, no copied secrets. The token form stays because it is the reviewer's and
/// tinkerer's path, and because a fallback that exists is one that can be tested.
public struct SignInView: View {
    @Environment(SessionStore.self) private var session
    @State private var serverAddress = "memos.discomarder.live"
    @State private var token = ""
    @State private var showAdvanced = false

    public init() {}

    private var isSigningIn: Bool { session.state == .signingIn }

    public var body: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()
            VStack(spacing: DesignTokens.Space.section) {
                Spacer(minLength: 0)
                brand
                Spacer(minLength: 0)
                VStack(spacing: DesignTokens.Space.regular) {
                    primaryButton
                    Text("Opens the family sign-on. This app never sees the password.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    // A failed sign-in has to be READ, not noticed: a red footnote under a
                    // button is what "the button does nothing" looks like from a device. This is
                    // the same notice card the timeline uses for everything it cannot do.
                    if let error = session.lastError {
                        NoticeCard(text: error, tone: .error)
                    }
                }
                Button("Advanced") { showAdvanced = true }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, DesignTokens.Space.snug)
            }
            .padding(.horizontal, DesignTokens.Space.section)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .tint(DesignTokens.accent)
        .sheet(isPresented: $showAdvanced) {
            AdvancedSignInSheet(
                serverAddress: $serverAddress,
                token: $token,
                isSigningIn: isSigningIn
            ) {
                await session.signIn(serverAddress: serverAddress, token: token)
            }
        }
    }

    private var brand: some View {
        VStack(spacing: DesignTokens.Space.roomy) {
            AppMark()
            Text("memosng")
                .font(.largeTitle.weight(.semibold))
            Text("Everything the household wrote down, in one place.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var primaryButton: some View {
        Button {
            Task {
                await session.signInNatively(
                    serverAddress: serverAddress,
                    deviceName: UIDevice.current.name,
                    presenter: WebAuthenticationLoginPresenter()
                )
            }
        } label: {
            Group {
                if isSigningIn {
                    ProgressView().tint(.white)
                } else {
                    Text("Sign in").fontWeight(.semibold)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, DesignTokens.Space.snug)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.roundedRectangle(radius: DesignTokens.Radius.tile))
        .controlSize(.large)
        .tint(DesignTokens.accent)
        .disabled(serverAddress.isEmpty || isSigningIn)
    }
}

/// The app's mark, drawn rather than shipped as a bitmap: the sign-in screen is in a package, the
/// icon lives in the app target's catalogue, and a package that reached into the app's assets
/// would be the dependency rule pointing the wrong way.
struct AppMark: View {
    @ScaledMetric(relativeTo: .largeTitle) private var side = DesignTokens.Metric.signInMark

    var body: some View {
        RoundedRectangle(cornerRadius: side * 0.24, style: .continuous)
            .fill(DesignTokens.accent.gradient)
            .frame(width: side, height: side)
            .overlay {
                Image(systemName: "photo.stack")
                    .font(.system(size: side * 0.44, weight: .medium))
                    .foregroundStyle(.white)
            }
            .shadow(color: DesignTokens.accent.opacity(0.3), radius: 12, y: 6)
            .accessibilityHidden(true)
    }
}

/// The token path. It is a sheet, not a disclosure row, so the first screen does not have to carry
/// it: the people who need it will look for it, and nobody else has to read past it.
struct AdvancedSignInSheet: View {
    @Binding var serverAddress: String
    @Binding var token: String
    let isSigningIn: Bool
    let signIn: () async -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("memos.example.com", text: $serverAddress)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }
                Section {
                    SecureField("memos_pat_…", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button {
                        Task {
                            await signIn()
                            dismiss()
                        }
                    } label: {
                        if isSigningIn {
                            ProgressView()
                        } else {
                            Text("Sign in with this token")
                        }
                    }
                    .disabled(serverAddress.isEmpty || token.isEmpty || isSigningIn)
                } header: {
                    Text("Personal access token")
                } footer: {
                    Text(
                        "Create a personal access token in the memos web app, then paste it here."
                    )
                }
            }
            .navigationTitle("Advanced")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .tint(DesignTokens.accent)
        .presentationDetents([.medium, .large])
    }
}
