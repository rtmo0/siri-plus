import Foundation

/// The models a way of reaching a model offers, for the model pickers.
struct RouteModels {
    let options: [ModelOption]
    /// The title of the empty model ID, for providers that pick a default themselves.
    var defaultTitle: String?
    /// Effort levels while the model's own are unknown.
    let usualEfforts: [String]
}

extension AppModel {
    func models(for route: ModelCatalog.Route) -> RouteModels {
        switch route {
        case .claudeCode: RouteModels(options: accounts.claudeCodeModels.nonEmpty ?? ModelOption.claudeCodeDefaults, usualEfforts: ModelEffort.claudeLevels)
        case .claudeAPI: RouteModels(options: accounts.claudeAPIModels.nonEmpty ?? ModelOption.claudeAPIDefaults, usualEfforts: ModelEffort.claudeLevels)
        case .chatGPT: RouteModels(options: accounts.chatGPTModels, defaultTitle: String(localized: "Account default"), usualEfforts: ModelEffort.openAIAPILevels)
        case .openAIAPI: RouteModels(options: ModelOption.openAIAPIModels, defaultTitle: String(localized: "Default (GPT-6.1 Sol)"), usualEfforts: ModelEffort.openAIAPILevels)
        case .deepSeek: RouteModels(options: accounts.deepSeekModels.nonEmpty ?? ModelOption.deepSeekModels, usualEfforts: ModelEffort.deepSeekLevels)
        case .custom: RouteModels(options: accounts.customModels, defaultTitle: accounts.customModels.isEmpty ? nil : String(localized: "First listed model"), usualEfforts: [])
        }
    }

    /// Effort levels of a model; an empty ID is the provider's default (the first model a ChatGPT account lists).
    func efforts(of profile: ModelProfile) -> [String] {
        let models = models(for: profile.route)
        let chosen = profile.model.isEmpty ? ModelProfile.defaultModel(for: profile.route) : profile.model
        let id = chosen.isEmpty ? (profile.route == .openAIAPI ? ModelOption.openAIAPIDefault.id : models.options.first?.id) : chosen
        return models.options.first { $0.id == id }?.efforts ?? models.usualEfforts
    }

    /// The name the user gave, or the model's title as its provider lists it.
    func title(of profile: ModelProfile) -> String {
        let name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
        return automaticTitle(of: profile)
    }

    func automaticTitle(of profile: ModelProfile) -> String {
        let models = models(for: profile.route)
        let id = profile.model.isEmpty ? ModelProfile.defaultModel(for: profile.route) : profile.model
        if let option = models.options.first(where: { $0.id == id }) {
            // Claude Code's aliases ("Opus") and an account's own titles say nothing about the provider.
            return option.title.localizedCaseInsensitiveContains(profile.provider.title) || profile.provider == .custom
                ? option.title : "\(profile.provider.title) \(option.title)"
        }
        if id.isEmpty { return "\(preferences.providerName(profile.provider)) · \(models.defaultTitle ?? String(localized: "default"))" }
        return id
    }

    /// "Claude · Subscription · Automatic effort".
    func detail(of profile: ModelProfile) -> String {
        var parts = [preferences.providerName(profile.provider)]
        if profile.provider.offersAccountSignIn { parts.append(profile.auth.title) }
        if profile.provider != .custom {
            parts.append(String(localized: "Effort: \(ModelEffort.title(profile.effort))"))
        }
        return parts.joined(separator: " · ")
    }
}

extension Array {
    /// The array, or nil when it is empty, for falling back with `??`.
    var nonEmpty: Self? { isEmpty ? nil : self }
}
