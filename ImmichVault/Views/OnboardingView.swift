import SwiftUI

// MARK: - Onboarding / Setup View
// First-run experience: connect to Immich server and validate API key.

struct OnboardingView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var appState: AppState

    @State private var serverURL: String = ""
    @State private var apiKey: String = ""
    @State private var currentStep: OnboardingStep = .welcome
    @State private var isTestingConnection = false
    @State private var connectionError: String?
    @State private var serverVersion: String?
    @State private var userName: String?
    @State private var userEmail: String?

    enum OnboardingStep {
        case welcome
        case serverSetup
        case success
    }

    var body: some View {
        VStack(spacing: 0) {
            // Progress indicator
            onboardingProgress
                .padding(.top, IVSpacing.xxxl)

            Spacer()

            // Content
            Group {
                switch currentStep {
                case .welcome:
                    welcomeContent
                case .serverSetup:
                    serverSetupContent
                case .success:
                    successContent
                }
            }
            .frame(maxWidth: 520)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.ivBackground)
    }

    // MARK: - Progress Dots

    private var onboardingProgress: some View {
        HStack(spacing: IVSpacing.sm) {
            ForEach(Array([OnboardingStep.welcome, .serverSetup, .success].enumerated()), id: \.offset) { index, step in
                Circle()
                    .fill(stepIndex(currentStep) >= index ? Color.ivAccent : Color.ivBorder)
                    .frame(width: 8, height: 8)
                    .animation(.easeInOut(duration: 0.3), value: currentStep)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(stepIndex(currentStep) + 1) of 3")
    }

    private func stepIndex(_ step: OnboardingStep) -> Int {
        switch step {
        case .welcome: return 0
        case .serverSetup: return 1
        case .success: return 2
        }
    }

    // MARK: - Welcome

    private var welcomeContent: some View {
        VStack(spacing: IVSpacing.xxl) {
            Image(systemName: "shield.checkered")
                .font(.system(size: 64, weight: .thin))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.ivAccent, .purple],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            VStack(spacing: IVSpacing.md) {
                Text("Welcome to ImmichVault")
                    .font(IVFont.displayLarge)
                    .foregroundColor(.ivTextPrimary)

                Text("Safely upload your Photos library to Immich with full control over what gets uploaded, optimized, and preserved.")
                    .font(IVFont.body)
                    .foregroundColor(.ivTextSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            }

            VStack(spacing: IVSpacing.md) {
                featureRow(icon: "photo.on.rectangle.angled", title: "Photos Upload", subtitle: "Idempotent, never re-upload protection")
                featureRow(icon: "wand.and.stars", title: "Video Optimizer", subtitle: "Transcode & replace oversized videos")
                featureRow(icon: "lock.shield", title: "Secure by Default", subtitle: "API keys in Keychain, secrets redacted from logs")
            }
            .padding(.vertical, IVSpacing.lg)

            Button {
                withAnimation(.easeInOut(duration: 0.3)) {
                    currentStep = .serverSetup
                }
            } label: {
                Text("Get Started")
                    .font(IVFont.bodyMedium)
                    .frame(maxWidth: 200)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(IVSpacing.xxxl)
    }

    private func featureRow(icon: String, title: String, subtitle: String) -> some View {
        HStack(spacing: IVSpacing.md) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundColor(.ivAccent)
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: IVSpacing.xxxs) {
                Text(title)
                    .font(IVFont.bodyMedium)
                    .foregroundColor(.ivTextPrimary)
                Text(subtitle)
                    .font(IVFont.caption)
                    .foregroundColor(.ivTextSecondary)
            }

            Spacer()
        }
        .padding(.horizontal, IVSpacing.lg)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Server Setup

    private var serverSetupContent: some View {
        VStack(spacing: IVSpacing.xxl) {
            VStack(spacing: IVSpacing.md) {
                Image(systemName: "server.rack")
                    .font(.system(size: 40, weight: .thin))
                    .foregroundColor(.ivAccent)

                Text("Connect to Immich")
                    .font(IVFont.displayMedium)
                    .foregroundColor(.ivTextPrimary)

                Text("Enter your Immich server URL and API key to get started.")
                    .font(IVFont.body)
                    .foregroundColor(.ivTextSecondary)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: IVSpacing.lg) {
                VStack(alignment: .leading, spacing: IVSpacing.xs) {
                    Text("Server URL")
                        .font(IVFont.captionMedium)
                        .foregroundColor(.ivTextSecondary)
                    TextField("https://immich.example.com", text: $serverURL)
                        .textFieldStyle(.roundedBorder)
                        .font(IVFont.body)
                        .onSubmit { Task { await testConnection() } }
                }

                VStack(alignment: .leading, spacing: IVSpacing.xs) {
                    Text("API Key")
                        .font(IVFont.captionMedium)
                        .foregroundColor(.ivTextSecondary)
                    SecureField("Paste your Immich API key", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                        .font(IVFont.body)
                        .onSubmit { Task { await testConnection() } }

                    Text("Find this in Immich → Profile → Account Settings → API Keys")
                        .font(IVFont.caption)
                        .foregroundColor(.ivTextTertiary)
                }
            }
            .frame(maxWidth: 400)

            if let error = connectionError {
                HStack(spacing: IVSpacing.sm) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.ivError)
                    Text(error)
                        .font(IVFont.caption)
                        .foregroundColor(.ivError)
                }
                .padding(IVSpacing.md)
                .background {
                    RoundedRectangle(cornerRadius: IVCornerRadius.md)
                        .fill(Color.ivError.opacity(0.08))
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Error: \(error)")
            }

            HStack(spacing: IVSpacing.lg) {
                Button {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        currentStep = .welcome
                    }
                } label: {
                    Text("Back")
                        .frame(width: 80)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button {
                    Task { await testConnection() }
                } label: {
                    HStack(spacing: IVSpacing.sm) {
                        if isTestingConnection {
                            ProgressView()
                                .scaleEffect(0.7)
                                .frame(width: 14, height: 14)
                        }
                        Text(isTestingConnection ? "Testing..." : "Test Connection")
                    }
                    .frame(width: 160)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(serverURL.isEmpty || apiKey.isEmpty || isTestingConnection)
            }
        }
        .padding(IVSpacing.xxxl)
    }

    // MARK: - Success

    private var successContent: some View {
        VStack(spacing: IVSpacing.xxl) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundColor(.ivSuccess)

            VStack(spacing: IVSpacing.md) {
                Text("Connected!")
                    .font(IVFont.displayMedium)
                    .foregroundColor(.ivTextPrimary)

                Text("ImmichVault is ready to manage your photo library.")
                    .font(IVFont.body)
                    .foregroundColor(.ivTextSecondary)
            }

            if let userName, let userEmail, let serverVersion {
                VStack(spacing: IVSpacing.sm) {
                    infoRow(label: "User", value: "\(userName) (\(userEmail))")
                    infoRow(label: "Server", value: serverURL)
                    infoRow(label: "Version", value: serverVersion)
                }
                .padding(IVSpacing.lg)
                .background {
                    RoundedRectangle(cornerRadius: IVCornerRadius.lg)
                        .fill(Color.ivSurface)
                }
            }

            Button {
                settings.hasCompletedOnboarding = true
            } label: {
                Text("Open ImmichVault")
                    .font(IVFont.bodyMedium)
                    .frame(maxWidth: 200)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(IVSpacing.xxxl)
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(IVFont.captionMedium)
                .foregroundColor(.ivTextSecondary)
                .frame(width: 60, alignment: .leading)
            Text(value)
                .font(IVFont.body)
                .foregroundColor(.ivTextPrimary)
                .lineLimit(1)
            Spacer()
        }
    }

    // MARK: - Connection Test

    private func testConnection() async {
        isTestingConnection = true
        connectionError = nil

        do {
            let client = ImmichClient()
            let result = try await client.testConnection(
                serverURL: serverURL,
                apiKey: apiKey
            )

            // Save to Keychain and settings
            try KeychainManager.shared.save(apiKey, for: .immichAPIKey)
            settings.immichServerURL = serverURL

            serverVersion = result.server.version
            userName = result.user.name
            userEmail = result.user.email

            // Update app state
            appState.connectionStatus = .connected(
                version: result.server.version,
                user: result.user.name
            )
            appState.isConnectedToImmich = true
            appState.connectedServerVersion = result.server.version
            appState.connectedUserName = result.user.name
            appState.connectedUserEmail = result.user.email

            LogManager.shared.info("Onboarding: Successfully connected to Immich", category: .immichAPI)

            withAnimation(.easeInOut(duration: 0.3)) {
                currentStep = .success
            }
        } catch {
            connectionError = error.localizedDescription
            LogManager.shared.error("Onboarding: Connection failed - \(error.localizedDescription)", category: .immichAPI)
        }

        isTestingConnection = false
    }
}
