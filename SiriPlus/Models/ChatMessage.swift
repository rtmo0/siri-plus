import Foundation

struct ChatMessage: Identifiable, Equatable, Codable, Sendable {
    enum Role: String, Codable, Sendable {
        case user
        case assistant
    }

    let id: UUID
    let role: Role
    let text: String
    let createdAt: Date
    /// JPEG screenshot sent together with a user message.
    let imageJPEG: Data?
    /// Files the user attached to this message.
    let attachments: [ChatAttachment]

    init(role: Role, text: String, imageJPEG: Data? = nil, attachments: [ChatAttachment] = []) {
        self.id = UUID()
        self.role = role
        self.text = text
        self.createdAt = Date()
        self.imageJPEG = imageJPEG
        self.attachments = attachments
    }

    /// Every picture that goes to the model with this message.
    var images: [Data] {
        (imageJPEG.map { [$0] } ?? []) + attachments.compactMap(\.imageData)
    }

    /// The typed text followed by the text of attached documents.
    var promptText: String {
        ([text] + attachments.compactMap(\.promptBlock)).joined(separator: "\n\n")
    }
}

enum ReplyStyle: String, CaseIterable, Codable, Identifiable, Sendable {
    case brief
    case detailed

    var id: String { rawValue }

    var title: String {
        self == .brief ? String(localized: "Brief") : String(localized: "Detailed")
    }
}

enum AIProvider: String, CaseIterable, Codable, Identifiable, Sendable {
    case claude
    case openAI
    case deepSeek
    /// Any server with an OpenAI-compatible Chat Completions API: Ollama, LM Studio, OpenRouter, Groq…
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .claude: "Claude"
        case .openAI: "ChatGPT"
        case .deepSeek: "DeepSeek"
        case .custom: String(localized: "Other")
        }
    }

    /// Only Claude and ChatGPT have a subscription sign-in; the others are reached with a key or a server address.
    var offersAccountSignIn: Bool { self == .claude || self == .openAI }
}

/// A model chosen for live meeting hints, apart from the one that answers chats and writes summaries.
/// The provider's sign-in is shared; only the model and its effort differ.
struct HintModelChoice: Codable, Equatable, Sendable {
    var provider: AIProvider
    /// Empty uses the provider's model chosen above.
    var model = ""
    var effort = ModelEffort.automatic
}

enum AuthMethod: String, CaseIterable, Codable, Identifiable, Sendable {
    /// Browser sign-in to a Claude or ChatGPT account (subscription).
    case account
    case apiKey

    var id: String { rawValue }

    var title: String {
        self == .account ? String(localized: "Sign in with browser") : String(localized: "API key")
    }
}

/// Which cloud model answers, and how each provider is authenticated.
struct ModelSelection: Equatable, Sendable {
    var provider: AIProvider = .claude
    /// A Claude Code model (an alias such as "opus" or a model ID) or, with an API key, a Claude API model ID.
    var claudeModel = "opus"
    var claudeAuth: AuthMethod = .account
    /// Empty means the first model the ChatGPT account offers.
    var openAIModel = ""
    var openAIAuth: AuthMethod = .account
    /// Effort chosen in Settings for each provider, or `ModelEffort.automatic`.
    var claudeEffort = ModelEffort.automatic
    var openAIEffort = ModelEffort.automatic
    var deepSeekModel = ModelOption.deepSeekDefault.id
    var deepSeekEffort = ModelEffort.automatic
    /// An OpenAI-compatible server, such as "http://localhost:11434/v1"; empty when none is connected.
    var customBaseURL = ""
    /// Empty means the first model the server lists.
    var customModel = ""
    /// Live hints normally keep a light effort whatever is chosen; a model picked for hints uses its own.
    var appliesEffortToHints = false

    /// The way of reaching the chosen model.
    var route: ModelCatalog.Route {
        switch provider {
        case .claude: claudeAuth == .account ? .claudeCode : .claudeAPI
        case .openAI: openAIAuth == .account ? .chatGPT : .openAIAPI
        case .deepSeek: .deepSeek
        case .custom: .custom
        }
    }

    /// The chosen model of the chosen provider.
    var model: String {
        switch provider {
        case .claude: claudeModel
        case .openAI: openAIModel
        case .deepSeek: deepSeekModel
        case .custom: customModel
        }
    }

    /// The effort chosen for the chosen provider; servers of the "Other" provider take none.
    var effort: String {
        switch provider {
        case .claude: claudeEffort
        case .openAI: openAIEffort
        case .deepSeek: deepSeekEffort
        case .custom: ModelEffort.automatic
        }
    }

    /// This selection with another provider, its model and effort, for hints.
    func replacing(with choice: HintModelChoice) -> ModelSelection {
        var selection = self
        selection.provider = choice.provider
        selection.appliesEffortToHints = true
        let model = choice.model
        switch choice.provider {
        case .claude:
            if !model.isEmpty { selection.claudeModel = model }
            selection.claudeEffort = choice.effort
        case .openAI:
            if !model.isEmpty { selection.openAIModel = model }
            selection.openAIEffort = choice.effort
        case .deepSeek:
            if !model.isEmpty { selection.deepSeekModel = model }
            selection.deepSeekEffort = choice.effort
        case .custom:
            if !model.isEmpty { selection.customModel = model }
        }
        return selection
    }
}

enum HintMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case questionsAndTopic
    case questions
    case manual

    var id: String { rawValue }

    var title: String {
        switch self {
        case .questionsAndTopic: String(localized: "On questions and topic")
        case .questions: String(localized: "On questions only")
        case .manual: String(localized: "Only when asked")
        }
    }
}

struct AssistantPreferences: Codable, Equatable, Sendable {
    /// Speech recognition follows the system language unless a locale is chosen.
    static let systemLocale = "auto"

    var replyStyle: ReplyStyle = .brief
    var showTimestamps = true
    var provider: AIProvider = .claude
    /// The model Claude Code runs with a Claude account sign-in.
    var claudeModel = "opus"
    /// The model used with an Anthropic API key.
    var claudeAPIModel = "claude-opus-5-5"
    var claudeAuth: AuthMethod = .account
    var claudeEffort = ModelEffort.automatic
    var openAIModel = ""
    var openAIAuth: AuthMethod = .account
    var openAIEffort = ModelEffort.automatic
    var deepSeekModel = ModelOption.deepSeekDefault.id
    var deepSeekEffort = ModelEffort.automatic
    var customBaseURL = ""
    /// The name shown for the "Other" provider, such as "Ollama"; empty shows the server's host.
    var customName = ""
    var customModel = ""
    /// Nil: hints use the model above.
    var hintModel: HintModelChoice?
    var hintMode: HintMode = .questionsAndTopic
    /// Also suggest answers to questions the user asks aloud: for practice, or a meeting the user leads.
    var hintsOnOwnQuestions = false
    /// Glossaries switched on in Settings, by id: built-in ones ("it", "business") and imported files.
    var glossaries: Set<String> = ["it"]
    /// The user's own terms, one per line, in the glossary file format.
    var customTerms = ""
    var transcriptionLocale = systemLocale
    var capturesMicrophone = true
    /// Saves each meeting's sound as M4A next to its transcript. Off by default: recording needs consent.
    var recordsAudio = false
    /// Meetings older than this many days are deleted from the history; 0 keeps them forever.
    var historyRetentionDays = 0
    /// Offers to start a meeting when a call app starts recording, and to stop it when the call ends.
    var offersMeetingStart = true
    /// Siri+ panels stay out of screen sharing, recordings and screenshots.
    var hidesPanelsFromCapture = true
    /// Looks for new versions on GitHub at launch and twice a day.
    var checksForUpdates = true
    /// ⌃⌥Space opens the panel already listening, as Siri does.
    var dictatesOnShortcut = true

    init(
        replyStyle: ReplyStyle = .brief,
        showTimestamps: Bool = true,
        provider: AIProvider = .claude,
        claudeModel: String = "opus",
        claudeAPIModel: String = "claude-opus-5-5",
        claudeAuth: AuthMethod = .account,
        claudeEffort: String = ModelEffort.automatic,
        openAIModel: String = "",
        openAIAuth: AuthMethod = .account,
        openAIEffort: String = ModelEffort.automatic,
        deepSeekModel: String = ModelOption.deepSeekDefault.id,
        deepSeekEffort: String = ModelEffort.automatic,
        customBaseURL: String = "",
        customName: String = "",
        customModel: String = "",
        hintModel: HintModelChoice? = nil,
        hintsOnOwnQuestions: Bool = false,
        glossaries: Set<String> = ["it"],
        customTerms: String = "",
        hintMode: HintMode = .questionsAndTopic,
        transcriptionLocale: String = systemLocale,
        capturesMicrophone: Bool = true,
        recordsAudio: Bool = false,
        historyRetentionDays: Int = 0,
        offersMeetingStart: Bool = true,
        hidesPanelsFromCapture: Bool = true,
        checksForUpdates: Bool = true,
        dictatesOnShortcut: Bool = true
    ) {
        self.replyStyle = replyStyle
        self.showTimestamps = showTimestamps
        self.provider = provider
        self.claudeModel = claudeModel
        self.claudeAPIModel = claudeAPIModel
        self.claudeAuth = claudeAuth
        self.claudeEffort = claudeEffort
        self.openAIModel = openAIModel
        self.openAIAuth = openAIAuth
        self.openAIEffort = openAIEffort
        self.deepSeekModel = deepSeekModel
        self.deepSeekEffort = deepSeekEffort
        self.customBaseURL = customBaseURL
        self.customName = customName
        self.customModel = customModel
        self.hintModel = hintModel
        self.hintsOnOwnQuestions = hintsOnOwnQuestions
        self.glossaries = glossaries
        self.customTerms = customTerms
        self.hintMode = hintMode
        self.transcriptionLocale = transcriptionLocale
        self.capturesMicrophone = capturesMicrophone
        self.recordsAudio = recordsAudio
        self.historyRetentionDays = historyRetentionDays
        self.offersMeetingStart = offersMeetingStart
        self.hidesPanelsFromCapture = hidesPanelsFromCapture
        self.checksForUpdates = checksForUpdates
        self.dictatesOnShortcut = dictatesOnShortcut
    }

    // Settings saved by older versions lack the newer keys; keep what is there.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AssistantPreferences()
        replyStyle = try container.decodeIfPresent(ReplyStyle.self, forKey: .replyStyle) ?? defaults.replyStyle
        showTimestamps = try container.decodeIfPresent(Bool.self, forKey: .showTimestamps) ?? defaults.showTimestamps
        provider = (try? container.decodeIfPresent(AIProvider.self, forKey: .provider)) ?? defaults.provider
        // Siri+ 0.3 kept one Claude API model ID under "model" for both sign-in methods.
        let legacyModel = try decoder.container(keyedBy: LegacyKeys.self).decodeIfPresent(String.self, forKey: .model)
        claudeModel = try container.decodeIfPresent(String.self, forKey: .claudeModel)
            ?? legacyModel.map(ModelOption.claudeCodeAlias(forLegacy:)) ?? defaults.claudeModel
        claudeAPIModel = try container.decodeIfPresent(String.self, forKey: .claudeAPIModel) ?? legacyModel ?? defaults.claudeAPIModel
        claudeAuth = (try? container.decodeIfPresent(AuthMethod.self, forKey: .claudeAuth)) ?? defaults.claudeAuth
        claudeEffort = try container.decodeIfPresent(String.self, forKey: .claudeEffort) ?? defaults.claudeEffort
        openAIModel = try container.decodeIfPresent(String.self, forKey: .openAIModel) ?? defaults.openAIModel
        openAIAuth = (try? container.decodeIfPresent(AuthMethod.self, forKey: .openAIAuth)) ?? defaults.openAIAuth
        openAIEffort = try container.decodeIfPresent(String.self, forKey: .openAIEffort) ?? defaults.openAIEffort
        deepSeekModel = try container.decodeIfPresent(String.self, forKey: .deepSeekModel) ?? defaults.deepSeekModel
        deepSeekEffort = try container.decodeIfPresent(String.self, forKey: .deepSeekEffort) ?? defaults.deepSeekEffort
        customBaseURL = try container.decodeIfPresent(String.self, forKey: .customBaseURL) ?? defaults.customBaseURL
        customName = try container.decodeIfPresent(String.self, forKey: .customName) ?? defaults.customName
        customModel = try container.decodeIfPresent(String.self, forKey: .customModel) ?? defaults.customModel
        hintModel = try? container.decodeIfPresent(HintModelChoice.self, forKey: .hintModel)
        hintsOnOwnQuestions = try container.decodeIfPresent(Bool.self, forKey: .hintsOnOwnQuestions) ?? defaults.hintsOnOwnQuestions
        glossaries = try container.decodeIfPresent(Set<String>.self, forKey: .glossaries) ?? defaults.glossaries
        customTerms = try container.decodeIfPresent(String.self, forKey: .customTerms) ?? defaults.customTerms
        hintMode = (try? container.decodeIfPresent(HintMode.self, forKey: .hintMode)) ?? defaults.hintMode
        transcriptionLocale = try container.decodeIfPresent(String.self, forKey: .transcriptionLocale) ?? defaults.transcriptionLocale
        capturesMicrophone = try container.decodeIfPresent(Bool.self, forKey: .capturesMicrophone) ?? defaults.capturesMicrophone
        recordsAudio = try container.decodeIfPresent(Bool.self, forKey: .recordsAudio) ?? defaults.recordsAudio
        historyRetentionDays = try container.decodeIfPresent(Int.self, forKey: .historyRetentionDays) ?? defaults.historyRetentionDays
        offersMeetingStart = try container.decodeIfPresent(Bool.self, forKey: .offersMeetingStart) ?? defaults.offersMeetingStart
        hidesPanelsFromCapture = try container.decodeIfPresent(Bool.self, forKey: .hidesPanelsFromCapture) ?? defaults.hidesPanelsFromCapture
        checksForUpdates = try container.decodeIfPresent(Bool.self, forKey: .checksForUpdates) ?? defaults.checksForUpdates
        dictatesOnShortcut = try container.decodeIfPresent(Bool.self, forKey: .dictatesOnShortcut) ?? defaults.dictatesOnShortcut
    }

    private enum LegacyKeys: String, CodingKey {
        case model
    }

    var selection: ModelSelection {
        ModelSelection(
            provider: provider,
            claudeModel: claudeAuth == .account ? claudeModel : claudeAPIModel,
            claudeAuth: claudeAuth,
            openAIModel: openAIModel,
            openAIAuth: openAIAuth,
            claudeEffort: claudeEffort,
            openAIEffort: openAIEffort,
            deepSeekModel: deepSeekModel,
            deepSeekEffort: deepSeekEffort,
            customBaseURL: customBaseURL,
            customModel: customModel
        )
    }

    /// What answers live meeting hints: the model chosen for them, or the one above.
    var hintSelection: ModelSelection {
        hintModel.map(selection.replacing(with:)) ?? selection
    }

    /// The provider's name for status lines: "Claude", or the name given to an OpenAI-compatible server.
    func providerName(_ provider: AIProvider) -> String {
        guard provider == .custom else { return provider.title }
        let name = customName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? (URL(string: customBaseURL)?.host() ?? provider.title) : name
    }

    /// The languages speech is recognized in: the chosen one, or every language this Mac's user likely speaks.
    var speechLocales: [Locale] {
        guard transcriptionLocale == Self.systemLocale else { return [Locale(identifier: transcriptionLocale)] }
        return SpeechLanguages.automatic()
    }
}
