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
            accountsSection
        }
        .formStyle(.grouped)
        .sheet(item: $editing) { profile in
            ModelEditor(model: model, profile: profile, isNew: !preferences.models.contains { $0.id == profile.id })
        }
    }

    // MARK: Models

    private var modelsSection: some View {
        Section {
            ForEach(preferences.models) { profile in
                ModelRow(model: model, profile: profile) { editing = profile }
                    .contextMenu {
                        Button("Edit…") { editing = profile }
                        Button("Delete", role: .destructive) { model.preferences.remove(profile.id) }
                            .disabled(preferences.models.count == 1)
                    }
            }
            HStack {
                Spacer()
                Button("Add Model…", systemImage: "plus") {
                    editing = ModelProfile(provider: .claude, model: ModelProfile.defaultModel(for: .claudeCode))
                }
                .buttonStyle(.glass)
            }
        } header: {
            Label("Models", systemImage: "sparkles")
        } footer: {
            Footnote("Add each model you want to use: a subscription model, one with an API key, a local one. Then choose below what each one does.")
        }
    }

    // MARK: Routes

    private var routesSection: some View {
        Section {
            ForEach(ModelPurpose.allCases) { purpose in
                Picker(selection: routeBinding(purpose)) {
                    ForEach(preferences.models) { profile in
                        Text(verbatim: model.title(of: profile)).tag(profile.id)
                    }
                } label: {
                    Label(purpose.title, systemImage: purpose.symbol)
                }
                let profile = preferences.model(for: purpose)
                if !model.isReady(profile) {
                    Label("\(model.title(of: profile)) is not connected yet: sign in or add its key under Accounts and Keys.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if purpose == .hints, Self.slowEfforts.contains(profile.effort) {
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

    private static let slowEfforts: Set<String> = ["high", "xhigh", "max", "ultra"]

    private func routeBinding(_ purpose: ModelPurpose) -> Binding<UUID> {
        Binding(
            get: { model.preferences.model(for: purpose).id },
            set: { model.preferences.routes[purpose] = $0 }
        )
    }

    // MARK: Accounts

    /// Sign-ins and keys that are connected or that a model needs.
    private var connections: [ModelConnection] {
        let needed = Set(preferences.models.map(\.connection))
        return ModelConnection.allCases.filter { needed.contains($0) || model.isConnected($0) }
    }

    private var accountsSection: some View {
        Section {
            ForEach(connections, id: \.self) { connection in
                ConnectionRow(model: model, connection: connection, showsUsage: true)
            }
        } header: {
            Label("Accounts and Keys", systemImage: "person.badge.key")
        } footer: {
            Footnote("Models of one provider share its sign-in or key. Only your messages, a screenshot you take, and the latest part of the meeting transcript (when a hint is needed) go to the provider; with a local server nothing leaves the Mac.")
        }
    }
}

/// One added model: what it is, whether it is ready, and what it does.
private struct ModelRow: View {
    @ObservedObject var model: AppModel
    let profile: ModelProfile
    let edit: () -> Void

    var body: some View {
        let ready = model.isReady(profile)
        HStack(spacing: 10) {
            AccountLabel(title: model.title(of: profile), detail: model.detail(of: profile), state: ready ? .ok : .missing)
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
