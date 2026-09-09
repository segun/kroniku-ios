import AuthenticationServices
import GoogleSignIn
import SwiftUI
import UIKit

/// Authentication view using provider-issued OpenID Connect ID tokens.
struct AuthView: View {
    @Binding var isAuthenticated: Bool
    @State private var isLoading = false
    @State private var errorMessage: String?

    private let authService = AuthService.shared

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Spacer()

                VStack(spacing: 12) {
                    Text("Welcome to Kroniku")
                        .font(.system(size: 28, weight: .bold))
                    Text("Sign in securely to continue")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if let errorMessage {
                    HStack(alignment: .top) {
                        Image(systemName: "exclamationmark.circle.fill")
                        Text(errorMessage)
                        Spacer()
                    }
                    .padding()
                    .background(Color.red.opacity(0.1))
                    .foregroundColor(.red)
                    .cornerRadius(8)
                }

                SignInWithAppleButton(.signIn, onRequest: configureAppleRequest) { result in
                    handleAppleResult(result)
                }
                .signInWithAppleButtonStyle(.black)
                .frame(height: 50)
                .disabled(isLoading)

                Button(action: signInWithGoogle) {
                    HStack {
                        Image(systemName: "g.circle.fill")
                        Text("Continue with Google")
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(Color.white)
                    .foregroundColor(.black)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.4)))
                    .cornerRadius(8)
                }
                .disabled(isLoading)

                if isLoading {
                    ProgressView()
                        .padding(.top, 8)
                }

                Spacer()

                VStack(spacing: 8) {
                    Text("Backend Status")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Button(action: checkBackendStatus) {
                        Text("Check Connection")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .disabled(isLoading)
                }
            }
            .padding()
        }
    }

    private func configureAppleRequest(_ request: ASAuthorizationAppleIDRequest) {
        request.requestedScopes = [.email, .fullName]
    }

    private func handleAppleResult(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let identityToken = credential.identityToken,
                  let token = String(data: identityToken, encoding: .utf8) else {
                errorMessage = "Apple did not return a valid identity token."
                return
            }
            authenticate(provider: "apple", idToken: token)
        case .failure(let error):
            guard (error as? ASAuthorizationError)?.code != .canceled else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func signInWithGoogle() {
        guard let clientID = Bundle.main.object(forInfoDictionaryKey: "GOOGLE_CLIENT_ID") as? String,
              !clientID.isEmpty else {
            errorMessage = "Google Sign-In is not configured for this build."
            return
        }

        guard let presentingViewController = presentingViewController() else {
            errorMessage = "Unable to present Google Sign-In."
            return
        }

        isLoading = true
        errorMessage = nil
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)

        GIDSignIn.sharedInstance.signIn(withPresenting: presentingViewController) { result, error in
            if let error {
                Task { @MainActor in
                    isLoading = false
                    errorMessage = error.localizedDescription
                }
                return
            }

            guard let token = result?.user.idToken?.tokenString else {
                Task { @MainActor in
                    isLoading = false
                    errorMessage = "Google did not return a valid identity token."
                }
                return
            }
            Task { @MainActor in
                authenticate(provider: "google", idToken: token)
            }
        }
    }

    private func authenticate(provider: String, idToken: String) {
        errorMessage = nil
        isLoading = true

        Task {
            do {
                _ = try await authService.loginWithProvider(
                    provider: provider,
                    idToken: idToken,
                    clientDeviceId: getOrCreateDeviceId(),
                    appVersion: getAppVersion()
                )
                isAuthenticated = true
                isLoading = false
            } catch let error as HTTPError {
                errorMessage = error.errorDescription
                isLoading = false
            } catch {
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }

    private func checkBackendStatus() {
        Task {
            do {
                let status = try await authService.getBackendStatus()
                await MainActor.run {
                    errorMessage = "✅ Backend status: \(status.status)"
                }
            } catch {
                await MainActor.run {
                    errorMessage = "❌ Backend unreachable: \(error.localizedDescription)"
                }
            }
        }
    }

    private func presentingViewController() -> UIViewController? {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
              let rootViewController = scene.keyWindow?.rootViewController else {
            return nil
        }

        var viewController = rootViewController
        while let presented = viewController.presentedViewController {
            viewController = presented
        }
        return viewController
    }

    private func getOrCreateDeviceId() -> String {
        let keychain = KeychainService.shared
        if let existingId = try? keychain.retrieve(.clientDeviceId) {
            return existingId
        }

        let newId = "ios-\(UUID().uuidString.prefix(8))"
        try? keychain.store(newId, for: .clientDeviceId)
        return newId
    }

    private func getAppVersion() -> String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    }
}

#Preview {
    AuthView(isAuthenticated: .constant(false))
}
