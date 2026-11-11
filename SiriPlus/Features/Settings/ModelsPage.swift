import SwiftUI

/// The models the user added, what each one is used for, and the sign-ins and keys behind them.
struct ModelsPage: View {
    @ObservedObject var model: AppModel
    /// The model open in the editor; a new one until it is saved.
    @State private var editing: ModelProfile?

    private var preferences: AssistantPreferences { model.preferences }

    var body: some View {
        Form {
            modelsSection
            routesSection
        }
        .formStyle(.grouped)
        .sheet(item: $editing) { profile in
            ModelEditor(model: model, profile: profile, isNew: !preferences.models.contains { $0.id == profile.id })
        }
    }

    // MARK: Models

    private var modelsSection: some View {
        Section {
            if preferences.models.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("No models yet")
                        .font(.headline)
                    Text("Add the model Siri+ should answer with: Claude or ChatGPT by subscription, a model with an API key, DeepSeek or a local one.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
            }
            ForEach(preferences.models) { profile in
                ModelRow(model: model, profile: profile) { editing = profile }
                    .contextMenu {
                        Button("Edit…") { editing = profile }
                        Button("Delete", role: .destructive) { model.preferences.remove(profile.id) }
                    }
            }
            HStack {
                Spacer()
                let add = { editing = ModelProfile(provider: .claude, model: ModelProfile.defaultModel(for: .claudeCode)) }
                if preferences.models.isEmpty {
                    Button("Add Model…", systemImage: "plus", action: add)
                        .buttonStyle(.glassProminent)
                } else {
                    Button("Add Model…", systemImage: "plus", action: add)
                        .buttonStyle(.glass)
                }
            }
        } header: {
            Label("Models", systemImage: "sparkles")
        } footer: {
            Footnote("Add each model you want to use: a subscription model, one with an API key, a local one, and choose below what each one does. A model's window signs in, takes its key and shows its limits. Only your messages, a screenshot you take, and the latest part of the meeting transcript (when a hint is needed) go to the provider; with a local server nothing leaves the Mac.")
        }
    }

    // MARK: Routes

    @ViewBuilder
    private var routesSection: some View {
        if !preferences.models.isEmpty {
        Section {
            ForEach(ModelPurpose.allCases) { purpose in
                Picker(selection: routeBinding(purpose)) {
                    ForEach(preferences.models) { profile in
                        Text(verbatim: model.title(of: profile)).tag(profile.id)
                    }
                } label: {
                    Label(purpose.title, systemImage: purpose.symbol)
                }
                if let profile = preferences.model(for: purpose), !model.isReady(profile) {
                    Label("\(model.title(of: profile)) is not connected yet: open it in the list above to sign in or add its key.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if purpose == .hints, let profile = preferences.model(for: purpose), Self.slowEfforts.contains(profile.effort) {
                    Label("This model thinks long (\(ModelEffort.title(profile.effort))): hints may come late. Automatic keeps them brief.", systemImage: "tortoise")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        } header: {
            Label("Use For", systemImage: "arrow.triangle.branch")
        } footer: {
            Footnote("Hints have to arrive within seconds: a fast model with little or no thinking works best, such as Claude Haiku or DeepSeek Flash without thinking. A model’s “Automatic” effort keeps hints brief and thinks longer on detailed answers.")
        }
        }
    }

    private static let slowEfforts: Set<String> = ["high", "xhigh", "max", "ultra"]

    private func routeBinding(_ purpose: ModelPurpose) -> Binding<UUID> {
        Binding(
            get: { model.preferences.model(for: purpose)?.id ?? UUID() },
            set: { model.preferences.routes[purpose] = $0 }
        )
    }
}

/// One added model: what it is, whether it is ready, and what it does.
private struct ModelRow: View {
    @ObservedObject var model: AppModel
    let profile: ModelProfile
    let edit: () -> Void

    var body: some View {
        let ready = model.isReady(profile)
        let usage = ready ? model.usageSummary(of: profile) : nil
        HStack(spacing: 10) {
            AccountLabel(
                title: model.title(of: profile),
                detail: ready
                    ? model.detail(of: profile) + (usage.map { "\n" + $0 } ?? "")
                    : String(localized: "Not connected: open to sign in or add a key"),
                state: ready ? .ok : .warning
            )
            Spacer()
            ForEach(model.preferences.purposes(of: profile)) { purpose in
                Label(purpose.shortTitle, systemImage: purpose.symbol)
                    .font(.caption)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                    .help(purpose.title)
            }
            Button("Edit", systemImage: "slider.horizontal.3", action: edit)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Edit this model")
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: edit)
    }
}
