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

enum AuthMethod: String, CaseIterable, Codable, Identifiable, Sendable {
    /// Browser sign-in to a Claude or ChatGPT account (subscription).
    case account
    case apiKey

    var id: String { rawValue }

    var title: String {
        self == .account ? String(localized: "Subscription") : String(localized: "API key")
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
    /// The models the user added, in the order Settings lists them. Never empty.
    var models: [ModelProfile] = [.starter]
    /// Which model does what; a purpose without a route uses the first model.
    var routes: [ModelPurpose: UUID] = [:]
    /// The "Other" provider's OpenAI-compatible server, such as "http://localhost:11434/v1"; empty when none is connected.
    var customBaseURL = ""
    /// The name shown for that server, such as "Ollama"; empty shows its host.
    var customName = ""
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
        models: [ModelProfile] = [.starter],
        routes: [ModelPurpose: UUID] = [:],
        customBaseURL: String = "",
        customName: String = "",
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
        self.models = models.isEmpty ? [.starter] : models
        self.routes = routes
        self.customBaseURL = customBaseURL
        self.customName = customName
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
        customBaseURL = try container.decodeIfPresent(String.self, forKey: .customBaseURL) ?? defaults.customBaseURL
        customName = try container.decodeIfPresent(String.self, forKey: .customName) ?? defaults.customName
        if let models = try? container.decodeIfPresent([ModelProfile].self, forKey: .models), !models.isEmpty {
            self.models = models
            routes = (try? container.decodeIfPresent([ModelPurpose: UUID].self, forKey: .routes)) ?? [:]
        } else {
            // Siri+ 0.5.2 and earlier kept one model per provider and an optional separate model for hints.
            (models, routes) = try LegacyModels(from: decoder).profiles()
        }
        hintMode = (try? container.decodeIfPresent(HintMode.self, forKey: .hintMode)) ?? defaults.hintMode
        hintsOnOwnQuestions = try container.decodeIfPresent(Bool.self, forKey: .hintsOnOwnQuestions) ?? defaults.hintsOnOwnQuestions
        glossaries = try container.decodeIfPresent(Set<String>.self, forKey: .glossaries) ?? defaults.glossaries
        customTerms = try container.decodeIfPresent(String.self, forKey: .customTerms) ?? defaults.customTerms
        transcriptionLocale = try container.decodeIfPresent(String.self, forKey: .transcriptionLocale) ?? defaults.transcriptionLocale
        capturesMicrophone = try container.decodeIfPresent(Bool.self, forKey: .capturesMicrophone) ?? defaults.capturesMicrophone
        recordsAudio = try container.decodeIfPresent(Bool.self, forKey: .recordsAudio) ?? defaults.recordsAudio
        historyRetentionDays = try container.decodeIfPresent(Int.self, forKey: .historyRetentionDays) ?? defaults.historyRetentionDays
        offersMeetingStart = try container.decodeIfPresent(Bool.self, forKey: .offersMeetingStart) ?? defaults.offersMeetingStart
        hidesPanelsFromCapture = try container.decodeIfPresent(Bool.self, forKey: .hidesPanelsFromCapture) ?? defaults.hidesPanelsFromCapture
        checksForUpdates = try container.decodeIfPresent(Bool.self, forKey: .checksForUpdates) ?? defaults.checksForUpdates
        dictatesOnShortcut = try container.decodeIfPresent(Bool.self, forKey: .dictatesOnShortcut) ?? defaults.dictatesOnShortcut
    }

    // MARK: Models and routes

    /// The model that does this; the first one when no route is set or its model was removed.
    func model(for purpose: ModelPurpose) -> ModelProfile {
        routes[purpose].flatMap { id in models.first { $0.id == id } } ?? models.first ?? .starter
    }

    func selection(for purpose: ModelPurpose) -> ModelSelection {
        var selection = model(for: purpose).selection(serverAddress: customBaseURL)
        // Hints take the model's own effort; "Automatic" keeps them brief.
        selection.appliesEffortToHints = purpose == .hints
        return selection
    }

    /// What answers in the chat and the ask panel.
    var selection: ModelSelection { selection(for: .chat) }
    /// What answers live meeting hints.
    var hintSelection: ModelSelection { selection(for: .hints) }

    /// The purposes a model is chosen for.
    func purposes(of profile: ModelProfile) -> [ModelPurpose] {
        ModelPurpose.allCases.filter { model(for: $0).id == profile.id }
    }

    /// Adds a model or replaces the one with its id.
    mutating func save(_ profile: ModelProfile) {
        if let index = models.firstIndex(where: { $0.id == profile.id }) { models[index] = profile } else { models.append(profile) }
    }

    /// Removes a model unless it is the last one; its purposes fall back to the first model.
    mutating func remove(_ id: UUID) {
        guard models.count > 1 else { return }
        models.removeAll { $0.id == id }
        routes = routes.filter { $0.value != id }
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
