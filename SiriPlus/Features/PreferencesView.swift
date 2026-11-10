import AppKit
import SwiftUI

struct PreferencesView: View {
    @ObservedObject var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var apiKey = ""
    @State private var confirmsClaudeSignOut = false

    var body: some View {
        Form {
            modelSection
            usageSection
            meetingSection
            conversationSection
            accessSection
            aboutSection
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .task { await model.refreshAccounts() }
        .onAppear { model.permissions.refresh() }
        .onChange(of: scenePhase) {
            if scenePhase == .active {
                model.permissions.refresh()
                Task { await model.refreshAccounts() }
            }
        }
        .onChange(of: model.preferences.selection.route) { apiKey = "" }
    }

    // MARK: Sections

    private var modelSection: some View {
        Section {
            Picker("Provider", selection: $model.preferences.provider) {
                ForEach(AIProvider.allCases) { provider in
                    Text(verbatim: provider.title).tag(provider)
                }
            }
            .pickerStyle(.segmented)
            switch model.preferences.provider {
            case .claude:
                authPicker($model.preferences.claudeAuth)
                if model.preferences.claudeAuth == .account { claudeAccountRow } else {
                    keyField(for: .claude, prompt: "sk-ant-…", link: URL(string: "https://platform.claude.com/settings/keys")!)
                }
            case .openAI:
                authPicker($model.preferences.openAIAuth)
                if model.preferences.openAIAuth == .account { chatGPTAccountRow } else {
                    keyField(for: .openAI, prompt: "sk-…", link: URL(string: "https://platform.openai.com/api-keys")!)
                }
            case .deepSeek:
                keyField(for: .deepSeek, prompt: "sk-…", link: URL(string: "https://platform.deepseek.com/api_keys")!)
            }
            let choice = modelChoice
            modelPicker(choice.model, options: choice.options, defaultTitle: choice.defaultTitle)
            effortPicker(choice.effort, levels: choice.efforts)
        } header: {
            Label("Model", systemImage: "sparkles")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                footnote("Automatic effort: brief answers think briefly, detailed ones longer. Meeting hints always think briefly so they arrive in seconds.")
                footnote("Only your messages, a screenshot you take, and the latest part of the meeting transcript (when a hint is needed) go to the cloud.")
            }
        }
    }

    /// Subscription limits of a signed-in account, or the balance and token counts of a DeepSeek key.
    @ViewBuilder
    private var usageSection: some View {
        switch model.preferences.selection.route {
        case .claudeCode where model.accounts.claudeCode.signedIn:
            Section {
                UsageView(usage: model.usage.claude, error: model.usage.claudeError, isRefreshing: model.usage.isRefreshing) {
                    Task { await model.refreshUsage() }
                }
            } header: {
                Label("Usage Limits", systemImage: "gauge.with.dots.needle.50percent")
            }
        case .chatGPT where model.accounts.chatGPTEmail != nil:
            Section {
                UsageView(usage: model.usage.chatGPT, error: model.usage.chatGPTError, isRefreshing: model.usage.isRefreshing) {
                    Task { await model.refreshUsage() }
                }
            } header: {
                Label("Usage Limits", systemImage: "gauge.with.dots.needle.50percent")
            }
        case .deepSeek where model.accounts.hasKey(.deepSeek):
            Section {
                DeepSeekUsageView(usage: model.deepSeek)
            } header: {
                Label("Balance and Usage", systemImage: "chart.bar")
            } footer: {
                footnote("The balance comes from DeepSeek. Requests and tokens are counted on this Mac from DeepSeek’s replies; the cost is an estimate at list prices, with off-peak hours at half price.")
            }
        default:
            EmptyView()
        }
    }

    private var meetingSection: some View {
        Section {
            Picker("Hints", selection: $model.preferences.hintMode) {
                ForEach(HintMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            Picker("Speech language", selection: $model.preferences.transcriptionLocale) {
                Text("System (\(systemLanguageName))").tag(AssistantPreferences.systemLocale)
                Text(verbatim: "English").tag("en-US")
                Text(verbatim: "Русский").tag("ru-RU")
            }
            Toggle("Recognize my voice too (microphone)", isOn: $model.preferences.capturesMicrophone)
            Toggle("Save meeting audio (M4A)", isOn: $model.preferences.recordsAudio)
                .help("The call and your microphone are saved on this Mac as one M4A file with the meeting, about 30–60 MB an hour. Recording a conversation without consent is illegal in many countries: tell the participants.")
            Toggle("Offer to start a meeting when a call begins", isOn: $model.preferences.offersMeetingStart)
                .help("A call is noticed when Zoom, Teams, Telemost, Telegram or another call app uses the microphone for 10 seconds; in a browser, start the meeting yourself.")
            Toggle("Hide Siri+ panels from screen sharing and screenshots", isOn: $model.preferences.hidesPanelsFromCapture)
                .help("Turn off to take screenshots or record the hint panel. While it is off, people you share your screen with see the hints too.")
            Picker("Keep chats and meetings", selection: $model.preferences.historyRetentionDays) {
                Text("Forever").tag(0)
                ForEach([7, 30, 90, 365], id: \.self) { days in
                    Text("\(days) days").tag(days)
                }
            }
        } header: {
            Label("Meeting", systemImage: "waveform")
        } footer: {
            footnote("Speech is recognized on this Mac. ⌃⌥Space in any app asks for a hint.")
        }
    }

    private var conversationSection: some View {
        Section {
            Picker("Answer style", selection: $model.preferences.replyStyle) {
                ForEach(ReplyStyle.allCases) { style in
                    Text(style.title).tag(style)
                }
            }
            Toggle("Show message time", isOn: $model.preferences.showTimestamps)
            Toggle("Start dictation with ⌃⌥Space", isOn: $model.preferences.dictatesOnShortcut)
                .help("The shortcut opens the panel already listening; stop talking and the command is sent.")
            LabeledContent("Chats and meetings") {
                Button("Export…", action: exportHistory)
                    .buttonStyle(.glass)
                    .help("Save every meeting and chat as Markdown files in a folder you choose")
            }
        } header: {
            Label("Conversation", systemImage: "text.bubble")
        } footer: {
            footnote("Chats and meetings are saved on this Mac for the period chosen under Meeting.")
        }
    }

    private var accessSection: some View {
        Section {
            permissionRow(.screen, title: String(localized: "Screen & system audio recording"), symbol: "rectangle.dashed.badge.record")
            permissionRow(.microphone, title: String(localized: "Microphone"), symbol: "mic")
        } header: {
            Label("Screen and Audio Access", systemImage: "lock.shield")
        } footer: {
            footnote("“Allow” shows the macOS prompt and adds Siri+ to the list in System Settings. After switching screen recording on, restart Siri+. After an update, a switch that is already on may need to be turned off and on again.")
        }
    }

    private func permissionRow(_ kind: PermissionCenter.Kind, title: String, symbol: String) -> some View {
        let status = model.permissions.status(of: kind)
        return LabeledContent {
            HStack(spacing: 8) {
                switch status {
                case .granted:
                    statusBadge(isOK: true, ok: String(localized: "Allowed"), missing: "")
                case .notAsked:
                    Button("Allow") { Task { await model.permissions.request(kind) } }
                        .buttonStyle(.glassProminent)
                case .denied:
                    statusBadge(isOK: false, ok: "", missing: String(localized: "Turned off"))
                    Button("Open Settings") { model.permissions.openSettings(kind) }
                        .buttonStyle(.glass)
                        .help("Switch Siri+ on in this list, then come back. If it is already on, switch it off and on again: macOS treats every new build as a new app.")
                }
            }
        } label: {
            Label(title, systemImage: symbol)
        }
    }

    private var aboutSection: some View {
        Section {
            LabeledContent {
                HStack(spacing: 8) {
                    updateStatus
                    Button("Check Now") { Task { await model.updates.check(userInitiated: true) } }
                        .buttonStyle(.glass)
                        .disabled(model.updates.state == .checking)
                }
            } label: {
                Label {
                    Text(verbatim: "Siri+ \(model.updates.currentVersionText)")
                } icon: {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable()
                        .frame(width: 18, height: 18)
                }
            }
            Toggle("Check for updates automatically", isOn: $model.preferences.checksForUpdates)
        } header: {
            Label("Updates", systemImage: "arrow.down.circle")
        } footer: {
            footnote("New versions come from GitHub releases. Siri+ lives in the menu bar, not in the Dock.")
        }
    }

    @ViewBuilder
    private var updateStatus: some View {
        switch model.updates.state {
        case .checking:
            ProgressView().progressViewStyle(.linear).frame(width: 120)
        case .upToDate:
            statusBadge(isOK: true, ok: String(localized: "Up to date"), missing: "")
        case .available(let release):
            Button("Install \(release.version)") { Task { await model.updates.install() } }
                .buttonStyle(.glassProminent)
        case .installing:
            if let fraction = model.updates.progress?.fraction {
                ProgressView(value: fraction).progressViewStyle(.linear).frame(width: 120)
            } else {
                ProgressView().progressViewStyle(.linear).frame(width: 120)
            }
        case .failed:
            statusBadge(isOK: false, ok: "", missing: String(localized: "Check failed"))
        case .idle:
            EmptyView()
        }
    }

    // MARK: Providers

    private func authPicker(_ selection: Binding<AuthMethod>) -> some View {
        Picker("Sign-in", selection: selection) {
            ForEach(AuthMethod.allCases) { method in
                Text(method.title).tag(method)
            }
        }
        .pickerStyle(.segmented)
    }

    @ViewBuilder
    private var claudeAccountRow: some View {
        let status = model.accounts.claudeCode
        if !status.installed {
            LabeledContent {
                Link("Install Claude Code", destination: URL(string: "https://code.claude.com/docs/en/setup")!)
            } label: {
                accountLabel(String(localized: "Claude Code"), detail: String(localized: "Not installed"), state: .missing)
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
                accountLabel(
                    status.account ?? "Claude",
                    detail: status.subscription.map { $0.capitalized } ?? String(localized: "Requests use your Claude subscription limits through Claude Code."),
                    state: .ok
                )
            }
        } else {
            LabeledContent {
                signInButton(String(localized: "Sign In to Claude")) { await model.signInToClaude() }
            } label: {
                accountLabel(String(localized: "Claude account"), detail: String(localized: "Terminal opens with Claude Code’s sign-in; finish it in the browser. Siri+ notices when you are signed in."), state: .missing)
            }
        }
    }

    @ViewBuilder
    private var chatGPTAccountRow: some View {
        if let email = model.accounts.chatGPTEmail {
            LabeledContent {
                Button("Sign Out", role: .destructive) { Task { await model.signOutOfChatGPT() } }
                    .buttonStyle(.glass)
            } label: {
                accountLabel(email, detail: String(localized: "Requests use your ChatGPT subscription limits."), state: .ok)
            }
        } else {
            LabeledContent {
                signInButton(String(localized: "Sign In to ChatGPT")) { await model.signInToChatGPT() }
            } label: {
                accountLabel(String(localized: "ChatGPT account"), detail: String(localized: "The ChatGPT sign-in page opens in the browser."), state: .missing)
            }
        }
    }

    /// The models and effort levels of the way of reaching a model chosen above.
    private struct ModelChoice {
        let model: Binding<String>
        let effort: Binding<String>
        let options: [ModelOption]
        /// The title of the empty model ID, for providers that pick a default themselves.
        var defaultTitle: String?
        /// Levels of the chosen model; the provider's usual levels until its list is loaded.
        let efforts: [String]
    }

    private var modelChoice: ModelChoice {
        let accounts = model.accounts
        let route = model.preferences.selection.route
        let (selection, effort, options, defaultTitle, usual): (Binding<String>, Binding<String>, [ModelOption], String?, [String]) = switch route {
        case .claudeCode:
            ($model.preferences.claudeModel, $model.preferences.claudeEffort, accounts.claudeCodeModels.nonEmpty ?? ModelOption.claudeCodeDefaults, nil, ModelEffort.claudeLevels)
        case .claudeAPI:
            ($model.preferences.claudeAPIModel, $model.preferences.claudeEffort, accounts.claudeAPIModels.nonEmpty ?? ModelOption.claudeAPIDefaults, nil, ModelEffort.claudeLevels)
        case .chatGPT:
            ($model.preferences.openAIModel, $model.preferences.openAIEffort, accounts.chatGPTModels, String(localized: "Account default"), ModelEffort.openAIAPILevels)
        case .openAIAPI:
            ($model.preferences.openAIModel, $model.preferences.openAIEffort, ModelOption.openAIAPIModels, String(localized: "Default (GPT-6.1 Sol)"), ModelEffort.openAIAPILevels)
        case .deepSeek:
            ($model.preferences.deepSeekModel, $model.preferences.deepSeekEffort, accounts.deepSeekModels.nonEmpty ?? ModelOption.deepSeekModels, nil, ModelEffort.deepSeekLevels)
        }
        // An empty model is the provider's default: the first model a ChatGPT account lists.
        let chosen = selection.wrappedValue
        let id = chosen.isEmpty ? (route == .openAIAPI ? ModelOption.openAIAPIDefault.id : options.first?.id) : chosen
        let efforts = options.first { $0.id == id }?.efforts ?? usual
        return ModelChoice(model: selection, effort: effort, options: options, defaultTitle: defaultTitle, efforts: efforts)
    }

    // MARK: Export

    /// Asks for a folder, writes the history into a new folder inside it and shows it in Finder.
    private func exportHistory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Export Here")
        panel.message = String(localized: "Siri+ creates a folder with every meeting and chat as Markdown files.")
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        do {
            let folder = try model.exportHistory(into: directory)
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        } catch {
            model.errorMessage = String(localized: "The history was not exported. \(error.localizedDescription)")
        }
    }

    // MARK: Building blocks

    /// A model list as the provider gives it. A saved model missing from the list stays selectable.
    @ViewBuilder
    private func modelPicker(_ selection: Binding<String>, options: [ModelOption], defaultTitle: String? = nil) -> some View {
        let chosen = selection.wrappedValue
        Picker("Model", selection: selection) {
            if let defaultTitle {
                Text(verbatim: defaultTitle).tag("")
            }
            ForEach(options) { option in
                Text(verbatim: option.title).tag(option.id)
            }
            if !chosen.isEmpty, !options.contains(where: { $0.id == chosen }) {
                Text(verbatim: chosen).tag(chosen)
            }
        }
        if let detail = options.first(where: { $0.id == chosen })?.detail, !detail.isEmpty {
            Text(verbatim: detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// The effort levels the chosen model accepts; a model without effort gets none.
    @ViewBuilder
    private func effortPicker(_ selection: Binding<String>, levels: [String]) -> some View {
        if levels.isEmpty {
            LabeledContent("Effort") {
                Text("This model has no effort setting").foregroundStyle(.secondary)
            }
        } else {
            let chosen = selection.wrappedValue
            Picker("Effort", selection: selection) {
                Text(ModelEffort.title(ModelEffort.automatic)).tag(ModelEffort.automatic)
                ForEach(levels, id: \.self) { level in
                    Text(ModelEffort.title(level)).tag(level)
                }
                // A level the newly chosen model lacks is replaced by its nearest one when sent.
                if chosen != ModelEffort.automatic, !levels.contains(chosen) {
                    Text(ModelEffort.title(chosen)).tag(chosen)
                }
            }
            .help("How long the model thinks before answering. Deeper thinking is slower and uses more of the limits.")
        }
    }

    private enum RowState {
        case ok, missing, warning, progress

        var symbol: String {
            switch self {
            case .ok: "checkmark.circle.fill"
            case .missing: "person.crop.circle.badge.questionmark"
            case .warning: "exclamationmark.triangle.fill"
            case .progress: "clock"
            }
        }

        var color: Color {
            switch self {
            case .ok: .green
            case .missing, .progress: .secondary
            case .warning: .orange
            }
        }
    }

    private func accountLabel(_ title: String, detail: String, state: RowState) -> some View {
        HStack(spacing: 10) {
            Image(systemName: state.symbol)
                .font(.title2)
                .foregroundStyle(state.color)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                Text(verbatim: detail)
                    .font(.caption)
                    .foregroundStyle(state == .warning ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func statusBadge(isOK: Bool, ok: String, missing: String) -> some View {
        Label(isOK ? ok : missing, systemImage: isOK ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
            .foregroundStyle(isOK ? Color.green : Color.orange)
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

    /// A saved key with its check result, or a field that checks a new key before saving it.
    @ViewBuilder
    private func keyField(for provider: AIProvider, prompt: String, link: URL) -> some View {
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
                keyLabel(status, provider: provider)
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
                    Text("API key")
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

    private func keyLabel(_ status: KeyStatus, provider: AIProvider) -> some View {
        let title = String(localized: "\(provider.title) API key")
        return switch status {
        case .unchecked:
            accountLabel(title, detail: String(localized: "Saved in the keychain"), state: .ok)
        case .checking:
            accountLabel(title, detail: String(localized: "Checking the key…"), state: .progress)
        case .valid:
            accountLabel(title, detail: String(localized: "Saved in the keychain and working"), state: .ok)
        case .rejected(let message):
            accountLabel(title, detail: message, state: .warning)
        case .unverified(let message):
            accountLabel(title, detail: String(localized: "Saved, but not checked: \(message)"), state: .warning)
        }
    }

    private func footnote(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    /// "English, Russian": the languages "System" listens for.
    private var systemLanguageName: String {
        SpeechLanguages.automatic().compactMap { locale in
            let code = locale.language.languageCode?.identifier ?? locale.identifier
            return Locale.current.localizedString(forLanguageCode: code)?.capitalized ?? code
        }
        .joined(separator: ", ")
    }
}

private extension Array {
    /// The array, or nil when it is empty, for falling back with `??`.
    var nonEmpty: Self? { isEmpty ? nil : self }
}
