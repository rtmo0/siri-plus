import SwiftUI

/// One sign-in, key or server: its state and what can be done with it, or the way to connect it.
/// With `showsUsage`, a connected one also unfolds its limits or its request statistics.
struct ConnectionRow: View {
    @ObservedObject var model: AppModel
    let connection: ModelConnection
    var showsUsage = false

    @State private var apiKey = ""
    @State private var serverAddress = ""
    @State private var serverName = ""
    @State private var confirmsClaudeSignOut = false

    var body: some View {
        switch connection {
        case .claudeAccount: claudeAccount
        case .chatGPTAccount: chatGPTAccount
        case .claudeKey: keyField(.claude, prompt: "sk-ant-…", link: URL(string: "https://platform.claude.com/settings/keys")!)
        case .openAIKey: keyField(.openAI, prompt: "sk-…", link: URL(string: "https://platform.openai.com/api-keys")!)
        case .deepSeekKey: keyField(.deepSeek, prompt: "sk-…", link: URL(string: "https://platform.deepseek.com/api_keys")!)
        case .server: server
        }
        if showsUsage, model.isConnected(connection) { usage }
    }

    // MARK: Accounts

    @ViewBuilder
    private var claudeAccount: some View {
        let status = model.accounts.claudeCode
        if !status.installed {
            LabeledContent {
                Link("Install Claude Code", destination: URL(string: "https://code.claude.com/docs/en/setup")!)
            } label: {
                AccountLabel(title: String(localized: "Claude Code"), detail: String(localized: "Not installed"), state: .missing)
            }
        } else if status.signedIn {
            LabeledContent {
                Button("Sign Out", role: .destructive) { confirmsClaudeSignOut = true }
                    .buttonStyle(.glass)
                    .confirmationDialog("Sign out of Claude Code?", isPresented: $confirmsClaudeSignOut) {
                        Button("Sign Out", role: .destructive) { Task { await model.signOutOfClaude() } }
                    } message: {
                        Text("Siri+ uses Claude Code’s sign-in, so Claude Code in Terminal is signed out too.")
                    }
            } label: {
                AccountLabel(
                    title: status.account ?? "Claude",
                    detail: status.subscription.map { String(localized: "Claude subscription: \($0.capitalized)") }
                        ?? String(localized: "Requests use your Claude subscription limits through Claude Code."),
                    state: .ok
                )
            }
        } else {
            LabeledContent {
                signInButton(String(localized: "Sign In to Claude")) { await model.signInToClaude() }
            } label: {
                AccountLabel(title: String(localized: "Claude account"),
                             detail: String(localized: "Terminal opens with Claude Code’s sign-in; finish it in the browser. Siri+ notices when you are signed in."),
                             state: .missing)
            }
        }
    }

    @ViewBuilder
    private var chatGPTAccount: some View {
        if let email = model.accounts.chatGPTEmail {
            LabeledContent {
                Button("Sign Out", role: .destructive) { Task { await model.signOutOfChatGPT() } }
                    .buttonStyle(.glass)
            } label: {
                AccountLabel(title: email, detail: String(localized: "Requests use your ChatGPT subscription limits."), state: .ok)
            }
        } else {
            LabeledContent {
                signInButton(String(localized: "Sign In to ChatGPT")) { await model.signInToChatGPT() }
            } label: {
                AccountLabel(title: String(localized: "ChatGPT account"), detail: String(localized: "The ChatGPT sign-in page opens in the browser."), state: .missing)
            }
        }
    }

    private func signInButton(_ title: String, action: @escaping () async -> Void) -> some View {
        HStack(spacing: 8) {
            if model.isSigningIn {
                ProgressView().controlSize(.small)
                Text("Waiting for sign-in…").foregroundStyle(.secondary)
            }
            Button(title) { Task { await action() } }
                .buttonStyle(.glassProminent)
                .disabled(model.isSigningIn)
        }
    }

    // MARK: Keys

    /// A saved key with its check result, or a field that checks a new key before saving it.
    @ViewBuilder
    private func keyField(_ provider: AIProvider, prompt: String, link: URL) -> some View {
        if let status = model.accounts.keys[provider] {
            LabeledContent {
                HStack(spacing: 8) {
                    if status == .checking {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Check") { Task { await model.checkSavedKey(provider) } }
                            .buttonStyle(.glass)
                            .help("Ask \(provider.title) whether the key still works")
                    }
                    Button("Delete Key", role: .destructive) { model.deleteAPIKey(for: provider) }
                        .buttonStyle(.glass)
                }
            } label: {
                KeyLabel(status: status, title: String(localized: "\(provider.title) API key"))
            }
        } else {
            let isChecking = model.checkingNewKey == provider
            let canSave = !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.checkingNewKey == nil
            let save = {
                guard canSave else { return }
                Task {
                    await model.saveAPIKey(apiKey, for: provider)
                    if model.accounts.hasKey(provider) { apiKey = "" }
                }
            }
            LabeledContent {
                HStack(spacing: 8) {
                    SecureField("API key", text: $apiKey, prompt: Text(verbatim: prompt))
                        .labelsHidden()
                        .frame(minWidth: 200)
                        .disabled(isChecking)
                        .onSubmit(save)
                    if isChecking {
                        ProgressView().controlSize(.small)
                    }
                    Button(isChecking ? "Checking…" : "Check and Save", action: save)
                        .buttonStyle(.glassProminent)
                        .disabled(!canSave)
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(provider.title) API key")
                    Link("Get an API key", destination: link).font(.caption)
                }
            }
            if let error = model.newKeyErrors[provider] {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: Server

    /// Ready-made addresses of common OpenAI-compatible servers.
    private static let serverPresets: [(name: String, address: String)] = [
        ("Ollama", "http://localhost:11434/v1"),
        ("LM Studio", "http://localhost:1234/v1"),
        ("OpenRouter", "https://openrouter.ai/api/v1"),
        ("Groq", "https://api.groq.com/openai/v1"),
    ]

    @ViewBuilder
    private var server: some View {
        if let status = model.accounts.keys[.custom] {
            LabeledContent {
                HStack(spacing: 8) {
                    if status == .checking {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Check") { Task { await model.checkSavedKey(.custom) } }
                            .buttonStyle(.glass)
                            .help("Check that the server answers and list its models again")
                    }
                    Button("Disconnect", role: .destructive) { model.deleteAPIKey(for: .custom) }
                        .buttonStyle(.glass)
                }
            } label: {
                KeyLabel(status: status, title: model.preferences.providerName(.custom), working: model.preferences.customBaseURL)
            }
        } else {
            let isChecking = model.checkingNewKey == .custom
            let canConnect = !serverAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.checkingNewKey == nil
            let connect = {
                guard canConnect else { return }
                Task {
                    await model.connectCustomServer(address: serverAddress, name: serverName, key: apiKey)
                    if model.accounts.hasKey(.custom) { serverAddress = ""; serverName = ""; apiKey = "" }
                }
            }
            LabeledContent {
                HStack(spacing: 8) {
                    TextField("Server address", text: $serverAddress, prompt: Text(verbatim: "http://localhost:11434/v1"))
                        .labelsHidden()
                        .frame(minWidth: 200)
                        .onSubmit(connect)
                    Menu("Presets") {
                        ForEach(Self.serverPresets, id: \.name) { preset in
                            Button(preset.name) {
                                serverAddress = preset.address
                                serverName = preset.name
                            }
                        }
                    }
                    .fixedSize()
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Server")
                    Text("Any OpenAI-compatible API: Ollama, LM Studio, OpenRouter, Groq…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            TextField("Name", text: $serverName, prompt: Text("Shown in the status line"))
            LabeledContent("API key") {
                HStack(spacing: 8) {
                    SecureField("API key", text: $apiKey, prompt: Text("Not needed for a local server"))
                        .labelsHidden()
                        .frame(minWidth: 200)
                        .disabled(isChecking)
                        .onSubmit(connect)
                    if isChecking {
                        ProgressView().controlSize(.small)
                    }
                    Button(isChecking ? "Checking…" : "Check and Connect", action: connect)
                        .buttonStyle(.glassProminent)
                        .disabled(!canConnect)
                }
            }
            if let error = model.newKeyErrors[.custom] {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: Usage

    @ViewBuilder
    private var usage: some View {
        switch connection {
        case .claudeAccount:
            DisclosureGroup("Usage limits") {
                UsageView(usage: model.usage.claude, error: model.usage.claudeError, isRefreshing: model.usage.isRefreshing) {
                    Task { await model.refreshUsage() }
                }
            }
        case .chatGPTAccount:
            DisclosureGroup("Usage limits") {
                UsageView(usage: model.usage.chatGPT, error: model.usage.chatGPTError, isRefreshing: model.usage.isRefreshing) {
                    Task { await model.refreshUsage() }
                }
            }
        case .claudeKey, .openAIKey, .deepSeekKey, .server:
            DisclosureGroup(connection == .deepSeekKey ? "Balance and usage" : "Usage") {
                VStack(alignment: .leading, spacing: 10) {
                    APIUsageView(usage: model.apiUsage, provider: connection.provider)
                }
            }
        }
    }
}
