import AppKit
import Combine

/// Whether Siri+ panels show up in screen sharing, recordings and screenshots, as chosen in Settings.
/// Hidden by default, so the other side of a call never sees the hints.
@MainActor
enum PanelCapture {
    static var isHidden = true {
        didSet { for window in windows.allObjects { window.sharingType = sharingType } }
    }
    private static var sharingType: NSWindow.SharingType { isHidden ? .none : .readOnly }
    private static let windows = NSHashTable<NSWindow>.weakObjects()

    static func register(_ window: NSWindow) {
        windows.add(window)
        window.sharingType = sharingType
    }
}

/// Chat and Meeting each keep their own history inside the tab.
enum WorkspaceTab: String, CaseIterable, Identifiable {
    case chat
    case meeting
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chat: String(localized: "Chat")
        case .meeting: String(localized: "Meeting")
        case .settings: String(localized: "Settings")
        }
    }

    var symbol: String {
        switch self {
        case .chat: "sparkles"
        case .meeting: "waveform"
        case .settings: "slider.horizontal.3"
        }
    }
}

/// What Siri+ knows about a saved API key.
enum KeyStatus: Equatable, Sendable {
    /// Saved earlier and not checked since launch.
    case unchecked
    case checking
    case valid
    /// The provider refused the key: requests would fail until it is replaced.
    case rejected(String)
    /// The provider could not be reached to check it; the key may well work.
    case unverified(String)
}

/// Sign-in state of every way to reach a model, shown in Settings.
struct ProviderAccounts: Equatable {
    var claudeCode = ClaudeCodeStatus()
    var chatGPTEmail: String?
    /// Saved API keys; a provider without a key is missing.
    var keys: [AIProvider: KeyStatus] = [:]
    /// Models listed for the signed-in account or the key; empty until loaded.
    var claudeCodeModels: [ModelOption] = []
    var claudeAPIModels: [ModelOption] = []
    var chatGPTModels: [ModelOption] = []
    var deepSeekModels: [ModelOption] = []
    var customModels: [ModelOption] = []

    func hasKey(_ provider: AIProvider) -> Bool { keys[provider] != nil }

    /// A saved key the provider has not refused.
    func hasUsableKey(_ provider: AIProvider) -> Bool {
        switch keys[provider] {
        case nil, .rejected: false
        default: true
        }
    }

    func isReady(_ selection: ModelSelection) -> Bool {
        switch selection.route {
        case .claudeCode: claudeCode.signedIn
        case .claudeAPI: hasUsableKey(.claude)
        case .chatGPT: chatGPTEmail != nil
        case .openAIAPI: hasUsableKey(.openAI)
        case .deepSeek: hasUsableKey(.deepSeek)
        case .custom: hasUsableKey(.custom)
        }
    }
}

/// Credential sources the app model manages. Tests replace them with in-memory fakes.
struct Credentials {
    var claudeKey: any SecretStoring = KeychainStore(account: "anthropic-api-key")
    var openAIKey: any SecretStoring = KeychainStore(account: "openai-api-key")
    var deepSeekKey: any SecretStoring = KeychainStore(account: "deepseek-api-key")
    /// The optional key of the "Other" provider's server.
    var customKey: any SecretStoring = KeychainStore(account: "custom-api-key")
    var chatGPT = ChatGPTAccount()
    var claudeCodeStatus: @Sendable () async -> ClaudeCodeStatus = { await ClaudeCodeBackend.status() }
    var claudeCodeSignOut: @Sendable () async throws -> Void = { try await ClaudeCodeBackend.signOut() }
    var claudeUsage: @Sendable () async throws -> AccountUsage = { try await ClaudeCodeBackend.usage() }
    var claudeCodeModels: @Sendable () async throws -> [ModelOption] = { try await ClaudeCodeBackend.models() }
    /// Lists the key's models, which also checks the key.
    var claudeAPIModels: @Sendable (String) async throws -> [ModelOption] = { try await ClaudeClient(apiKey: $0).models() }
    var openAIKeyCheck: @Sendable (String) async throws -> Void = { try await OpenAIAPIBackend.checkKey($0) }
    /// Reads the balance, which also checks the key.
    var deepSeekBalance: @Sendable (String) async throws -> DeepSeekBalance = { try await ChatCompletionsClient.deepSeek(apiKey: $0).balance() }
    var deepSeekModels: @Sendable (String) async throws -> [ModelOption] = { try await ChatCompletionsClient.deepSeek(apiKey: $0).models() }
    /// Lists an OpenAI-compatible server's models, which also checks its address and key.
    var customModels: @Sendable (URL, String?) async throws -> [ModelOption] = { try await ChatCompletionsClient(base: $0, apiKey: $1).models() }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var selectedTab: WorkspaceTab? = .chat
    /// The saved chat on screen; nil until the first message of a new chat.
    @Published private(set) var currentChatID: UUID?
    @Published var draft = ""
    @Published var preferences: AssistantPreferences {
        didSet {
            preferencesStore.save(preferences)
            PanelCapture.isHidden = preferences.hidesPanelsFromCapture
            if preferences.historyRetentionDays != oldValue.historyRetentionDays {
                history.removeExpired()
                chats.removeExpired()
            }
        }
    }
    @Published private(set) var messages: [ChatMessage] = []
    /// The finished meeting the current conversation is about.
    @Published private(set) var chatMeeting: MeetingRecord?
    /// Text of the reply being streamed; moved into `messages` when it ends.
    @Published private(set) var partialReply = ""
    @Published private(set) var isReplying = false
    @Published private(set) var isCapturing = false
    @Published private(set) var snapshot: ScreenSnapshot?
    /// Files waiting to go with the next message, from the panel or the chat.
    @Published private(set) var pendingAttachments: [ChatAttachment] = []
    /// Audio and video files whose speech is still being recognized; sending waits for them.
    @Published private(set) var processingAttachments: [String] = []
    @Published private(set) var accounts = ProviderAccounts() {
        didSet { syncCatalog() }
    }
    @Published private(set) var isSigningIn = false
    /// Why the last answer did not come; shown in the conversation, cleared by the next question.
    @Published private(set) var replyFailure: ModelErrorReport?
    /// The provider whose new key is being checked before it is saved.
    @Published private(set) var checkingNewKey: AIProvider?
    /// Why a new key was not saved, per provider.
    @Published private(set) var newKeyErrors: [AIProvider: String] = [:]
    @Published var errorMessage: String?

    let meeting: MeetingModel
    let history: MeetingHistory
    let chats: ChatHistory
    let callMonitor: CallMonitor
    let updates: UpdateModel
    let voice: VoiceInput
    let permissions = PermissionCenter()
    let usage: UsageModel
    /// Glossaries for speech recognition and for restoring misheard terms.
    let glossaries: GlossaryLibrary
    /// Requests and tokens of API keys and servers, and the DeepSeek balance.
    let apiUsage: APIUsageModel
    /// Shows the floating hint panel; set by the app scene.
    var showHintPanel: (() -> Void)?

    private let assistant: any AssistantService
    private let screenCapture: any ScreenCapturing
    private let preferencesStore: PreferencesStore
    private let credentials: Credentials
    private let catalog: ModelCatalog
    private var replyTask: Task<Void, Never>?
    private var activeReplyID: UUID?
    private var captureID: UUID?
    private var meetingChanges: AnyCancellable?

    init(
        assistant: (any AssistantService & HintService & SummaryService)? = nil,
        meetingService: any MeetingService = LiveMeetingService(),
        screenCapture: any ScreenCapturing = ScreenCaptureService(),
        preferencesStore: PreferencesStore = PreferencesStore(),
        credentials: Credentials = Credentials(),
        historyStore: MeetingHistoryStore = MeetingHistoryStore(),
        chatStore: ChatHistoryStore = ChatHistoryStore(),
        microphoneUsage: any MicrophoneUsageSource = CoreAudioMicrophoneUsage(),
        updateChecker: any UpdateChecking = GitHubUpdateChecker(),
        meetingTiming: MeetingModel.Timing = MeetingModel.Timing(),
        usageLedgers: UsageLedgers = UsageLedgers(),
        glossaries: GlossaryLibrary = GlossaryLibrary()
    ) {
        self.glossaries = glossaries
        let catalog = ModelCatalog()
        let assistant = assistant ?? CloudAssistantService(
            claudeAPI: ClaudeAPIBackend(keyStore: credentials.claudeKey, ledgers: usageLedgers),
            claudeCode: ClaudeCodeBackend(),
            openAIAPI: OpenAIAPIBackend(keyStore: credentials.openAIKey, ledgers: usageLedgers),
            chatGPT: ChatGPTAccountBackend(account: credentials.chatGPT),
            deepSeek: DeepSeekBackend(keyStore: credentials.deepSeekKey, ledgers: usageLedgers),
            custom: { [customKey = credentials.customKey] address in
                ChatCompletionsBackend(base: ChatCompletionsClient.normalizedBase(address), keyStore: customKey, ledgers: usageLedgers)
            },
            catalog: catalog
        )
        self.assistant = assistant
        self.catalog = catalog
        self.screenCapture = screenCapture
        self.preferencesStore = preferencesStore
        self.credentials = credentials
        let preferences = preferencesStore.load()
        self.preferences = preferences
        PanelCapture.isHidden = preferences.hidesPanelsFromCapture
        var currentPreferences: () -> AssistantPreferences = { preferences }
        meeting = MeetingModel(service: meetingService, hintService: assistant, timing: meetingTiming, recordingURL: historyStore.recordingURL(for:),
                               vocabulary: { glossaries.activeTerms(currentPreferences()) }) {
            currentPreferences()
        }
        history = MeetingHistory(store: historyStore, summaries: assistant,
                                 vocabulary: { glossaries.activeTerms(currentPreferences()).promptText }) { currentPreferences() }
        chats = ChatHistory(store: chatStore) { currentPreferences() }
        callMonitor = CallMonitor(meeting: meeting, usage: microphoneUsage) { currentPreferences().offersMeetingStart }
        updates = UpdateModel(checker: updateChecker) { currentPreferences().checksForUpdates }
        voice = VoiceInput()
        let chatGPTAccount = credentials.chatGPT
        usage = UsageModel(fetchClaude: credentials.claudeUsage, fetchChatGPT: { try await chatGPTAccount.usage() })
        let deepSeekKey = credentials.deepSeekKey, fetchDeepSeekBalance = credentials.deepSeekBalance
        apiUsage = APIUsageModel(ledgers: usageLedgers) {
            guard let key = try deepSeekKey.read(), !key.isEmpty else { throw DeepSeekError.missingAPIKey }
            return try await fetchDeepSeekBalance(key)
        }
        currentPreferences = { [unowned self] in self.preferences }
        for provider in AIProvider.allCases where provider != .custom && (try? store(for: provider).read())?.isEmpty == false {
            accounts.keys[provider] = .unchecked
        }
        // The "Other" provider is connected by its address; its key is optional.
        if !preferences.customBaseURL.isEmpty { accounts.keys[.custom] = .unchecked }
        meeting.onFinish = { [history] in history.add($0) }
        // Views observing the app model also follow meeting and history state (menu bar icon, sidebar badge, errors).
        meetingChanges = meeting.objectWillChange.merge(with: history.objectWillChange, voice.objectWillChange, permissions.objectWillChange, chats.objectWillChange, usage.objectWillChange, apiUsage.objectWillChange, glossaries.objectWillChange)
            .sink { [weak self] in self?.objectWillChange.send() }
    }

    var isModelReady: Bool { preferences.selection.map(accounts.isReady) ?? false }
    /// Whether the model chosen for meeting hints can answer.
    var isHintModelReady: Bool { preferences.hintSelection.map(accounts.isReady) ?? false }

    /// Whether this model's sign-in, key or server is ready.
    func isReady(_ profile: ModelProfile) -> Bool {
        accounts.isReady(profile.selection(serverAddress: preferences.customBaseURL))
    }

    /// Whether a sign-in, key or server is connected, whatever models use it.
    func isConnected(_ connection: ModelConnection) -> Bool {
        switch connection {
        case .claudeAccount: accounts.claudeCode.signedIn
        case .chatGPTAccount: accounts.chatGPTEmail != nil
        case .claudeKey: accounts.hasKey(.claude)
        case .openAIKey: accounts.hasKey(.openAI)
        case .deepSeekKey: accounts.hasKey(.deepSeek)
        case .server: accounts.hasKey(.custom)
        }
    }

    @discardableResult
    func send(_ text: String) -> Task<Void, Never>? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isReplying, processingAttachments.isEmpty else { return nil }

        errorMessage = nil
        messages.append(ChatMessage(role: .user, text: trimmed, imageJPEG: snapshot?.jpegData, attachments: pendingAttachments))
        clearSnapshot()
        pendingAttachments = []
        saveChat()
        return requestReply()
    }

    /// Asks the model again after a failed answer, with the same question.
    @discardableResult
    func retryReply() -> Task<Void, Never>? {
        guard !isReplying, messages.last?.role == .user else { return nil }
        return requestReply()
    }

    /// Streams the model's answer to the conversation as it stands. A failure stays in the conversation as
    /// an error card with the code and the service's response, until the next question or a retry.
    private func requestReply() -> Task<Void, Never>? {
        guard let selection = preferences.selection else {
            replyFailure = .noModel(for: .chat)
            return nil
        }
        replyFailure = nil
        isReplying = true
        partialReply = ""
        let requestID = UUID()
        activeReplyID = requestID
        let request = AssistantRequest(messages: messages, replyStyle: preferences.replyStyle, selection: selection, meeting: chatMeeting)
        replyTask = Task { [weak self, assistant] in
            var failure: Error?
            do {
                for try await fragment in assistant.reply(to: request) {
                    guard let self, self.activeReplyID == requestID else { return }
                    self.partialReply += fragment
                }
            } catch {
                failure = error
            }
            guard let self, self.activeReplyID == requestID else { return }
            if let failure, !(failure is CancellationError) {
                self.replyFailure = ModelErrorReport(failure, modelTitle: self.preferences.model(for: .chat).map(self.title(of:)))
            }
            self.finishReply()
        }
        return replyTask
    }

    func stopReply() {
        replyTask?.cancel()
        finishReply()
    }

    func newConversation() {
        stopReply()
        messages = []
        currentChatID = nil
        chatMeeting = nil
        draft = ""
        pendingAttachments = []
        clearSnapshot()
        errorMessage = nil
        replyFailure = nil
        selectedTab = .chat
    }

    /// Shows a saved chat; a chat about a meeting keeps answering from that meeting.
    func openChat(_ id: UUID) {
        guard id != currentChatID, let conversation = chats.conversation(id) else { return }
        stopReply()
        messages = conversation.messages
        currentChatID = id
        chatMeeting = conversation.meetingID.flatMap { meetingID in history.records.first { $0.id == meetingID } }
        draft = ""
        pendingAttachments = []
        clearSnapshot()
        errorMessage = nil
        replyFailure = nil
        selectedTab = .chat
    }

    func deleteChat(_ id: UUID) {
        if id == currentChatID { newConversation() }
        chats.delete(id)
    }

    /// Starts or stops a spoken command. The text is sent when the user falls silent or stops it.
    func toggleDictation() async {
        if voice.isListening {
            await voice.stop(deliver: true)
            return
        }
        guard !isReplying else { return }
        await voice.start(locales: preferences.speechLocales) { [weak self] text in
            self?.draft = ""
            self?.send(text)
        }
        if let error = voice.errorMessage { errorMessage = error }
    }

    /// Stops listening and leaves the recognized words in the text field for editing.
    func keepDictationAsDraft() async {
        guard voice.isListening else { return }
        await voice.stop(deliver: false)
        // Stopping flushes the last words, so the text is read afterwards.
        let text = voice.dictation.text
        if !text.isEmpty { draft = text }
    }

    /// Starts a new conversation about a finished meeting.
    func askAbout(_ meeting: MeetingRecord) {
        newConversation()
        chatMeeting = meeting
    }

    func captureScreen() async {
        guard !isCapturing else { return }
        let id = UUID()
        captureID = id
        isCapturing = true
        errorMessage = nil
        do {
            let captured = try await screenCapture.captureMainDisplay()
            guard captureID == id else { return }
            snapshot = captured
        } catch {
            guard captureID == id else { return }
            errorMessage = String(localized: "No screenshot. Check Screen Recording access in macOS settings and try again. \(error.localizedDescription)")
        }
        guard captureID == id else { return }
        isCapturing = false
        captureID = nil
    }

    /// Reads the files on this Mac and keeps them for the next message; unsupported files are reported.
    /// The speech in audio and video files is recognized on this Mac and attached as its transcript.
    func attach(_ urls: [URL]) {
        var failures: [String] = []
        for url in urls {
            if MediaTranscriber.isMedia(url) {
                transcribe(url)
                continue
            }
            do {
                pendingAttachments.append(try ChatAttachment.load(from: url))
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        errorMessage = failures.isEmpty ? nil : failures.joined(separator: "\n")
    }

    /// Attaches what ⌘V brought: copied files as if they were dropped, a copied picture as an image.
    func attach(_ pasted: PastedContent) {
        switch pasted {
        case .files(let urls):
            attach(urls)
        case .image(let image):
            do {
                pendingAttachments.append(try ChatAttachment.pasted(image))
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func transcribe(_ url: URL) {
        let name = url.lastPathComponent
        processingAttachments.append(name)
        let locales = preferences.speechLocales
        Task {
            do {
                let result = try await MediaTranscriber.transcribe(url, locales: locales)
                let header = String(localized: "Transcript of the speech in this file, recognized automatically (\(result.locale.identifier)):")
                pendingAttachments.append(ChatAttachment(name: name, content: .text("\(header)\n\(result.text)")))
            } catch {
                errorMessage = error.localizedDescription
            }
            if let index = processingAttachments.firstIndex(of: name) { processingAttachments.remove(at: index) }
        }
    }

    func removeAttachment(_ id: UUID) {
        pendingAttachments.removeAll { $0.id == id }
    }

    func clearSnapshot() {
        captureID = nil
        isCapturing = false
        snapshot = nil
    }

    // MARK: Export

    /// The chat on screen as Markdown; nil when it has no messages yet.
    var currentChatMarkdown: String? {
        guard !messages.isEmpty else { return nil }
        var conversation = currentChatID.flatMap(chats.conversation) ?? ChatConversation()
        conversation.messages = messages
        return conversation.markdown(meetingTitle: chatMeeting?.displayTitle)
    }

    /// Writes every meeting and chat as Markdown into a new folder inside `directory`.
    func exportHistory(into directory: URL) throws -> URL {
        try HistoryExport.write(meetings: history.records, chats: chats.conversations, into: directory, recording: history.recording(for:))
    }

    // MARK: Accounts

    /// Re-reads sign-in state: Claude Code status, ChatGPT tokens and the model lists.
    func refreshAccounts() async {
        accounts.claudeCode = await credentials.claudeCodeStatus()
        accounts.chatGPTEmail = await credentials.chatGPT.isSignedIn ? (await credentials.chatGPT.email ?? "ChatGPT") : nil
        if accounts.claudeCode.signedIn, accounts.claudeCodeModels.isEmpty {
            accounts.claudeCodeModels = (try? await credentials.claudeCodeModels()) ?? []
        }
        if accounts.chatGPTEmail != nil, accounts.chatGPTModels.isEmpty {
            accounts.chatGPTModels = (try? await credentials.chatGPT.models()) ?? []
        }
        // Keys are checked once per launch and again while they could not be reached; the DeepSeek balance
        // is fetched every time, quietly.
        for provider in AIProvider.allCases {
            switch accounts.keys[provider] {
            case .unchecked?: await checkSavedKey(provider)
            case .unverified?: await checkSavedKey(provider, quietly: true)
            case .valid? where provider == .deepSeek: await checkSavedKey(provider, quietly: true)
            default: break
            }
        }
        await refreshUsage()
    }

    /// Checks a saved key (or the "Other" provider's server) and loads what it gives access to.
    /// - Parameter quietly: keeps the current status on screen while checking.
    func checkSavedKey(_ provider: AIProvider, quietly: Bool = false) async {
        guard accounts.hasKey(provider) else { return }
        let key = (try? store(for: provider).read()) ?? ""
        guard provider == .custom || !key.isEmpty else { return }
        if !quietly { accounts.keys[provider] = .checking }
        let status = await check(key, for: provider)
        // The key may have been deleted meanwhile.
        if accounts.hasKey(provider) { accounts.keys[provider] = status }
    }

    /// Asks the provider whether it accepts the key; on success, keeps its models and balance.
    /// - Parameter address: the "Other" provider's server; the saved one when nil.
    private func check(_ key: String, for provider: AIProvider, address: URL? = nil) async -> KeyStatus {
        do {
            switch provider {
            case .claude:
                accounts.claudeAPIModels = try await credentials.claudeAPIModels(key)
            case .openAI:
                try await credentials.openAIKeyCheck(key)
            case .deepSeek:
                apiUsage.show(try await credentials.deepSeekBalance(key))
                if let models = try? await credentials.deepSeekModels(key), !models.isEmpty {
                    accounts.deepSeekModels = models
                }
            case .custom:
                guard let base = address ?? ChatCompletionsClient.normalizedBase(preferences.customBaseURL) else {
                    throw CustomServerError.invalidAddress
                }
                accounts.customModels = try await credentials.customModels(base, key.isEmpty ? nil : key)
            }
            return .valid
        } catch ClaudeError.http(status: 401, _, _) {
            let message = provider == .custom
                ? String(localized: "The server did not accept the key. Check it, or leave the field empty for a server without one.")
                : String(localized: "\(provider.title) did not accept this key. Check that it is copied in full and not revoked.")
            return .rejected(message)
        } catch {
            return .unverified(error.localizedDescription)
        }
    }

    /// Lets requests send only the efforts the listed models accept.
    private func syncCatalog() {
        if !accounts.claudeCodeModels.isEmpty { catalog.update(accounts.claudeCodeModels, for: .claudeCode) }
        if !accounts.claudeAPIModels.isEmpty { catalog.update(accounts.claudeAPIModels, for: .claudeAPI) }
        if !accounts.deepSeekModels.isEmpty { catalog.update(accounts.deepSeekModels, for: .deepSeek) }
        catalog.update(accounts.customModels, for: .custom)
        if !accounts.chatGPTModels.isEmpty { catalog.update(accounts.chatGPTModels, for: .chatGPT) }
    }

    /// Re-reads how much of each subscription is left.
    func refreshUsage() async {
        await usage.refresh(claude: accounts.claudeCode.signedIn, chatGPT: accounts.chatGPTEmail != nil)
    }

    /// Checks a new key with its provider and saves it in the keychain unless the provider refuses it.
    /// A key that could not be checked (no connection) is saved and marked as unverified.
    func saveAPIKey(_ key: String, for provider: AIProvider) async {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, checkingNewKey == nil else { return }
        checkingNewKey = provider
        newKeyErrors[provider] = nil
        defer { checkingNewKey = nil }
        let status = await check(trimmed, for: provider)
        if case .rejected(let message) = status {
            newKeyErrors[provider] = message
            if provider == .deepSeek { apiUsage.clearBalance() }
            return
        }
        do {
            try store(for: provider).save(trimmed)
            accounts.keys[provider] = status
        } catch {
            newKeyErrors[provider] = String(localized: "The key was not saved. \(error.localizedDescription)")
        }
    }

    func deleteAPIKey(for provider: AIProvider) {
        do {
            try store(for: provider).delete()
            accounts.keys[provider] = nil
            newKeyErrors[provider] = nil
            switch provider {
            case .claude: accounts.claudeAPIModels = []
            case .openAI: break
            case .deepSeek:
                accounts.deepSeekModels = []
                apiUsage.clearBalance()
            case .custom:
                accounts.customModels = []
                preferences.customBaseURL = ""
            }
        } catch {
            errorMessage = String(localized: "The key was not deleted. \(error.localizedDescription)")
        }
    }

    /// Connects an OpenAI-compatible server: checks that it answers and lists models, then saves its address,
    /// name and optional key. A server that refuses the key is not saved; one that does not answer is saved as unverified.
    func connectCustomServer(address: String, name: String, key: String) async {
        guard checkingNewKey == nil else { return }
        guard let base = ChatCompletionsClient.normalizedBase(address) else {
            newKeyErrors[.custom] = CustomServerError.invalidAddress.localizedDescription
            return
        }
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        checkingNewKey = .custom
        newKeyErrors[.custom] = nil
        defer { checkingNewKey = nil }
        let status = await check(key, for: .custom, address: base)
        if case .rejected(let message) = status {
            newKeyErrors[.custom] = message
            return
        }
        do {
            if key.isEmpty { try credentials.customKey.delete() } else { try credentials.customKey.save(key) }
        } catch {
            newKeyErrors[.custom] = String(localized: "The key was not saved. \(error.localizedDescription)")
            return
        }
        preferences.customBaseURL = base.absoluteString
        preferences.customName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        accounts.keys[.custom] = status
    }

    /// Opens Claude Code's browser sign-in in Terminal and waits until it reports success.
    func signInToClaude() async {
        isSigningIn = true
        defer { isSigningIn = false }
        do {
            try await ClaudeCodeBackend.openSignIn()
            for _ in 0..<100 {
                try await Task.sleep(for: .seconds(3))
                accounts.claudeCode = await credentials.claudeCodeStatus()
                if accounts.claudeCode.signedIn {
                    // Another account may offer other models.
                    accounts.claudeCodeModels = []
                    await refreshAccounts()
                    return
                }
            }
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func signOutOfClaude() async {
        do {
            try await credentials.claudeCodeSignOut()
        } catch {
            errorMessage = error.localizedDescription
        }
        accounts.claudeCode = await credentials.claudeCodeStatus()
        accounts.claudeCodeModels = []
    }

    func signInToChatGPT() async {
        isSigningIn = true
        defer { isSigningIn = false }
        do {
            try await credentials.chatGPT.signIn { url in await MainActor.run { NSWorkspace.shared.open(url) } }
            NSApplication.shared.activate()
            accounts.chatGPTModels = []
            await refreshAccounts()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func signOutOfChatGPT() async {
        try? await credentials.chatGPT.signOut()
        accounts.chatGPTEmail = nil
        accounts.chatGPTModels = []
    }

    private func store(for provider: AIProvider) -> any SecretStoring {
        switch provider {
        case .claude: credentials.claudeKey
        case .openAI: credentials.openAIKey
        case .deepSeek: credentials.deepSeekKey
        case .custom: credentials.customKey
        }
    }

    /// Saves the chat on screen, creating it on its first message.
    private func saveChat() {
        guard !messages.isEmpty else { return }
        let id = currentChatID ?? UUID()
        var conversation = chats.conversation(id) ?? ChatConversation(id: id)
        conversation.messages = messages
        conversation.meetingID = chatMeeting?.id
        chats.upsert(conversation)
        currentChatID = id
    }

    private func finishReply() {
        // Keep whatever already arrived, including a reply stopped by the user.
        let text = partialReply.trimmingCharacters(in: .whitespacesAndNewlines)
        if activeReplyID != nil, !text.isEmpty {
            messages.append(ChatMessage(role: .assistant, text: text))
            saveChat()
            usage.refreshSoon(claude: accounts.claudeCode.signedIn, chatGPT: accounts.chatGPTEmail != nil)
        }
        partialReply = ""
        isReplying = false
        activeReplyID = nil
        replyTask = nil
    }
}
