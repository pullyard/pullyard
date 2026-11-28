import SwiftUI

enum DeviceFlow {
    struct Code: Equatable {
        let deviceCode: String
        let userCode: String
        let verificationURL: URL
        let expiresIn: Int
        let interval: Int
    }

    static let scopes = "repo notifications read:org"
    static let customClientKey = "mobile.oauth.clientID"

    static var bundledClientID: String {
        let value = (Bundle.main.object(forInfoDictionaryKey: "PYGitHubOAuthClientID") as? String ?? "").trimmingCharacters(in: .whitespaces)
        return value.hasPrefix("$(") ? "" : value
    }

    static var clientID: String {
        let custom = (UserDefaults.standard.string(forKey: customClientKey) ?? "").trimmingCharacters(in: .whitespaces)
        return custom.isEmpty ? bundledClientID : custom
    }

    private static func post(_ url: String, _ params: [String: String]) async throws -> [String: Any] {
        guard let target = URL(string: url) else { throw GitHubError.message("Invalid address.") }
        var request = URLRequest(url: target)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var components = URLComponents()
        components.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)
        let data: Data
        do { (data, _) = try await URLSession.shared.data(for: request) }
        catch let error as URLError { throw GitHubError.map(urlError: error) }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw GitHubError.message("GitHub returned an unexpected response.") }
        return object
    }

    static func friendly(_ code: String, description: String?) -> String {
        switch code {
        case "access_denied": "Sign-in was cancelled on GitHub."
        case "expired_token": "The code expired. Request a new one and try again."
        case "incorrect_client_credentials", "invalid_client", "unauthorized_client": "GitHub didn't accept this OAuth client ID."
        case "device_flow_disabled": "Device sign-in is turned off for this OAuth app. Enable it in the app's settings on GitHub, or use a token."
        case "incorrect_device_code", "invalid_grant": "The code is no longer valid. Request a new one."
        default: description ?? code.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    static func start(clientID: String) async throws -> Code {
        let object = try await post("https://github.com/login/device/code", ["client_id": clientID, "scope": scopes])
        if let error = object["error"] as? String { throw GitHubError.message(friendly(error, description: object["error_description"] as? String)) }
        guard let device = object["device_code"] as? String, let user = object["user_code"] as? String,
              let uri = (object["verification_uri"] as? String).flatMap(URL.init(string:)) else {
            throw GitHubError.message("Device sign-in isn't available for this client ID.")
        }
        return Code(deviceCode: device, userCode: user, verificationURL: uri, expiresIn: object["expires_in"] as? Int ?? 900, interval: object["interval"] as? Int ?? 5)
    }

    static func poll(clientID: String, code: Code) async throws -> String {
        var interval = max(code.interval, 5)
        let deadline = Date().addingTimeInterval(TimeInterval(code.expiresIn))
        while Date() < deadline {
            try await Task.sleep(for: .seconds(interval))
            let object = try await post("https://github.com/login/oauth/access_token", [
                "client_id": clientID,
                "device_code": code.deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            ])
            if let token = object["access_token"] as? String { return token }
            switch object["error"] as? String {
            case "authorization_pending": continue
            case "slow_down": interval += 5
            case let error?: throw GitHubError.message(friendly(error, description: object["error_description"] as? String))
            default: throw GitHubError.message("GitHub returned an unexpected response.")
            }
        }
        throw GitHubError.message("The code expired before it was confirmed. Request a new one.")
    }
}

struct DeviceFlowSheet: View {
    let clientID: String
    let completion: (String) async -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var code: DeviceFlow.Code?
    @State private var errorMessage: String?
    @State private var copied = false
    @State private var flowTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            VStack(spacing: 22) {
                if let code {
                    Text("Enter this code on GitHub").mobileFont(size: 15, weight: .medium).foregroundStyle(MobileTheme.muted)
                    Button {
                        UIPasteboard.general.string = code.userCode
                        copied = true
                    } label: {
                        HStack(spacing: 10) {
                            Text(code.userCode).mobileFont(size: 34, weight: .bold, design: .monospaced).tracking(3).foregroundStyle(MobileTheme.ink)
                            Image(systemName: copied ? "checkmark" : "doc.on.doc").foregroundStyle(MobileTheme.accent)
                        }
                        .padding(.horizontal, 22).padding(.vertical, 14)
                        .pyGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous), interactive: true, fallback: MobileTheme.card)
                    }
                    .buttonStyle(.pyPlain)
                    .sensoryFeedback(.success, trigger: copied) { _, new in new }
                    .accessibilityLabel("Code \(code.userCode). Double-tap to copy")
                    Button {
                        UIPasteboard.general.string = code.userCode
                        openURL(code.verificationURL)
                    } label: {
                        Label("Copy code & open GitHub", systemImage: "safari")
                            .mobileFont(size: 16, weight: .semibold).foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .contentShape(Capsule())
                            .pyGlass(in: Capsule(), tint: MobileTheme.accentFill, interactive: true, fallback: MobileTheme.accentFill)
                    }
                    .buttonStyle(.pyPlain)
                    PullYardLoader(title: "Waiting for you to approve on GitHub…", size: 56)
                } else if let errorMessage {
                    ErrorStateView(title: "Sign-in didn't start", message: errorMessage) { start() }
                } else {
                    PullYardLoader(title: "Requesting a code…", size: 72)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(BrandBackdrop())
            .navigationTitle("Sign in with GitHub")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { flowTask?.cancel(); dismiss() } } }
        }
        .pySheetStyle()
        .presentationDetents([.medium, .large])
        .onAppear { if code == nil && flowTask == nil { start() } }
        .onDisappear { flowTask?.cancel() }
    }

    private func start() {
        errorMessage = nil
        code = nil
        flowTask?.cancel()
        flowTask = Task {
            do {
                let next = try await DeviceFlow.start(clientID: clientID)
                code = next
                let token = try await DeviceFlow.poll(clientID: clientID, code: next)
                await completion(token)
                dismiss()
            } catch {
                guard !error.isCancellation else { return }
                code = nil
                errorMessage = error.localizedDescription
            }
        }
    }
}
