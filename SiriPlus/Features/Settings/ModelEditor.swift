import SwiftUI

/// Adds a model or changes one: the provider, how it is reached, which model, how hard it thinks, its name.
/// A provider that is not connected yet can be signed in or given a key right here.
struct ModelEditor: View {
    @ObservedObject var model: AppModel
    @State var profile: ModelProfile
    let isNew: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Picker("Provider", selection: $profile.provider) {
                        ForEach(AIProvider.allCases) { provider in
                            Text(verbatim: provider.title).tag(provider)
                        }
                    }
                    if profile.provider.offersAccountSignIn {
                        Picker("Sign-in", selection: $profile.auth) {
                            ForEach(AuthMethod.allCases) { method in
                                Text(method.title).tag(method)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                    ConnectionRow(model: model, connection: profile.connection, showsUsage: true)
                }
                Section {
                    let models = model.models(for: profile.route)
                    if profile.provider == .custom, models.options.isEmpty {
                        TextField("Model", text: $profile.model, prompt: Text(verbatim: "llama3.2"))
                            .help("The model name as the server knows it")
                    } else {
                        ModelPicker(selection: $profile.model, models: models)
                    }
                    if profile.provider != .custom {
                        EffortPicker(selection: $profile.effort, levels: model.efforts(of: profile))
                    }
                    TextField("Name", text: $profile.name, prompt: Text(verbatim: model.automaticTitle(of: profile)))
                        .help("How the model is called in Settings; empty uses the model's own name")
                } footer: {
                    if profile.provider != .custom {
                        Footnote("Automatic effort: brief answers think briefly, detailed ones longer, meeting hints briefly.")
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                if !isNew {
                    Button("Delete Model", role: .destructive) {
                        model.preferences.remove(profile.id)
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save") {
                    model.preferences.save(profile)
                    dismiss()
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(minWidth: 560, idealWidth: 600, minHeight: 440)
        .navigationTitle(isNew ? "Add Model" : "Edit Model")
        .onChange(of: profile.route) { old, new in
            guard old != new else { return }
            // Another provider or sign-in lists other models.
            profile.model = ModelProfile.defaultModel(for: new)
            profile.effort = ModelEffort.automatic
            if !profile.provider.offersAccountSignIn { profile.auth = .apiKey }
        }
        .task { await model.refreshAccounts() }
    }
}
