import Foundation

/// What a model is used for. Each purpose is routed to one of the models the user added.
enum ModelPurpose: String, Codable, CodingKeyRepresentable, CaseIterable, Identifiable, Sendable {
    case chat
    case hints
    case summaries

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chat: String(localized: "Chat and ask panel")
        case .hints: String(localized: "Meeting hints")
        case .summaries: String(localized: "Meeting summaries")
        }
    }

    var shortTitle: String {
        switch self {
        case .chat: String(localized: "Chat")
        case .hints: String(localized: "Hints")
        case .summaries: String(localized: "Summaries")
        }
    }

    var symbol: String {
        switch self {
        case .chat: "text.bubble"
        case .hints: "bolt"
        case .summaries: "doc.text"
        }
    }
}

/// The sign-in or key a model is reached with. Several models can share one.
enum ModelConnection: Hashable, CaseIterable, Sendable {
    case claudeAccount, claudeKey, chatGPTAccount, openAIKey, deepSeekKey, server

    var provider: AIProvider {
        switch self {
        case .claudeAccount, .claudeKey: .claude
        case .chatGPTAccount, .openAIKey: .openAI
        case .deepSeekKey: .deepSeek
        case .server: .custom
        }
    }
}

/// A model the user added in Settings: a provider, how it is reached, which of its models and how hard it thinks.
struct ModelProfile: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var provider: AIProvider
    /// Subscription or API key, for Claude and ChatGPT; DeepSeek and servers of the "Other" provider ignore it.
    var auth: AuthMethod = .account
    /// Empty: the provider's default (ChatGPT's first model, OpenAI's default, a server's first model).
    var model = ""
    var effort = ModelEffort.automatic
    /// Empty: named after the model.
    var name = ""

    /// Claude Opus through the Claude Code sign-in: what Siri+ 0.5.2 and earlier used when nothing was chosen.
    static let starter = ModelProfile(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, provider: .claude, model: "opus")

    var usesAccount: Bool { provider.offersAccountSignIn && auth == .account }

    var connection: ModelConnection {
        switch provider {
        case .claude: usesAccount ? .claudeAccount : .claudeKey
        case .openAI: usesAccount ? .chatGPTAccount : .openAIKey
        case .deepSeek: .deepSeekKey
        case .custom: .server
        }
    }

    var route: ModelCatalog.Route {
        switch connection {
        case .claudeAccount: .claudeCode
        case .claudeKey: .claudeAPI
        case .chatGPTAccount: .chatGPT
        case .openAIKey: .openAIAPI
        case .deepSeekKey: .deepSeek
        case .server: .custom
        }
    }

    /// The model a route starts with when a new model is added or the sign-in changes.
    static func defaultModel(for route: ModelCatalog.Route) -> String {
        switch route {
        case .claudeCode: "opus"
        case .claudeAPI: "claude-opus-5-5"
        case .deepSeek: ModelOption.deepSeekDefault.id
        case .chatGPT, .openAIAPI, .custom: ""
        }
    }

    /// The request settings for this model.
    func selection(serverAddress: String) -> ModelSelection {
        var selection = ModelSelection(provider: provider)
        let model = model.isEmpty ? Self.defaultModel(for: route) : model
        switch provider {
        case .claude:
            selection.claudeAuth = auth
            selection.claudeModel = model
            selection.claudeEffort = effort
        case .openAI:
            selection.openAIAuth = auth
            selection.openAIModel = model
            selection.openAIEffort = effort
        case .deepSeek:
            selection.deepSeekModel = model
            selection.deepSeekEffort = effort
        case .custom:
            selection.customBaseURL = serverAddress
            selection.customModel = model
        }
        return selection
    }
}

/// Model settings as Siri+ 0.5.2 and earlier saved them: one model per provider, the provider in use,
/// and an optional separate model for hints. Read once to build the list of models.
struct LegacyModels: Decodable {
    private struct HintChoice: Decodable {
        var provider: AIProvider
        var model = ""
        var effort = ModelEffort.automatic

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            provider = try container.decode(AIProvider.self, forKey: .provider)
            model = try container.decodeIfPresent(String.self, forKey: .model) ?? ""
            effort = try container.decodeIfPresent(String.self, forKey: .effort) ?? ModelEffort.automatic
        }

        enum CodingKeys: String, CodingKey { case provider, model, effort }
    }

    private enum Keys: String, CodingKey {
        case provider, model, claudeModel, claudeAPIModel, claudeAuth, claudeEffort
        case openAIModel, openAIAuth, openAIEffort, deepSeekModel, deepSeekEffort, customModel, hintModel
    }

    private var provider: AIProvider = .claude
    private var claudeModel = "opus"
    private var claudeAPIModel = "claude-opus-5-5"
    private var claudeAuth: AuthMethod = .account
    private var claudeEffort = ModelEffort.automatic
    private var openAIModel = ""
    private var openAIAuth: AuthMethod = .account
    private var openAIEffort = ModelEffort.automatic
    private var deepSeekModel = ModelOption.deepSeekDefault.id
    private var deepSeekEffort = ModelEffort.automatic
    private var customModel = ""
    private var hint: HintChoice?
    /// Whether the saved settings had model keys at all; a fresh install has none.
    private(set) var isPresent = false

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        isPresent = !container.allKeys.isEmpty
        func value<T: Decodable>(_ key: Keys, _ fallback: T) -> T { ((try? container.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback }
        provider = value(.provider, provider)
        // Siri+ 0.3 kept one Claude API model ID under "model" for both sign-in methods.
        let oldest: String? = value(.model, nil)
        claudeModel = value(.claudeModel, oldest.map(ModelOption.claudeCodeAlias(forLegacy:)) ?? claudeModel)
        claudeAPIModel = value(.claudeAPIModel, oldest ?? claudeAPIModel)
        claudeAuth = value(.claudeAuth, claudeAuth)
        claudeEffort = value(.claudeEffort, claudeEffort)
        openAIModel = value(.openAIModel, openAIModel)
        openAIAuth = value(.openAIAuth, openAIAuth)
        openAIEffort = value(.openAIEffort, openAIEffort)
        deepSeekModel = value(.deepSeekModel, deepSeekModel)
        deepSeekEffort = value(.deepSeekEffort, deepSeekEffort)
        customModel = value(.customModel, customModel)
        hint = value(.hintModel, nil)
    }

    /// The model each provider had, with its effort.
    private func profile(_ provider: AIProvider, id: UUID = UUID()) -> ModelProfile {
        switch provider {
        case .claude: ModelProfile(id: id, provider: .claude, auth: claudeAuth, model: claudeAuth == .account ? claudeModel : claudeAPIModel, effort: claudeEffort)
        case .openAI: ModelProfile(id: id, provider: .openAI, auth: openAIAuth, model: openAIModel, effort: openAIEffort)
        case .deepSeek: ModelProfile(id: id, provider: .deepSeek, auth: .apiKey, model: deepSeekModel, effort: deepSeekEffort)
        case .custom: ModelProfile(id: id, provider: .custom, auth: .apiKey, model: customModel)
        }
    }

    /// The provider in use becomes the first model. Hints get the separate model chosen for them; without one
    /// they used the same model but always thought briefly, so a model with a chosen effort gets a brief copy.
    func profiles() -> ([ModelProfile], [ModelPurpose: UUID]) {
        let main = profile(provider, id: ModelProfile.starter.id)
        var hints: ModelProfile?
        if let hint {
            var profile = profile(hint.provider)
            if !hint.model.isEmpty { profile.model = hint.model }
            profile.effort = hint.effort
            hints = profile
        } else if main.effort != ModelEffort.automatic {
            var brief = main
            brief.id = UUID()
            brief.effort = ModelEffort.automatic
            hints = brief
        }
        guard let hints else { return ([main], [:]) }
        return ([main, hints], [.hints: hints.id])
    }
}
