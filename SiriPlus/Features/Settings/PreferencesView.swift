import AppKit
import SwiftUI

/// Settings in four pages: the models and what each one does, meetings, vocabulary, and the rest.
struct PreferencesView: View {
    enum Page: String, CaseIterable, Identifiable {
        case models, meetings, vocabulary, general

        var id: String { rawValue }
    }

    @ObservedObject var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @SceneStorage("settings.page") private var page = Page.models
    @State private var glossaryError: String?

    var body: some View {
        TabView(selection: $page) {
            ModelsPage(model: model)
                .tabItem { Label("Models", systemImage: "sparkles") }
                .tag(Page.models)
            Form { meetingSection }
                .formStyle(.grouped)
                .tabItem { Label("Meetings", systemImage: "waveform") }
                .tag(Page.meetings)
            Form { vocabularySection }
                .formStyle(.grouped)
                .tabItem { Label("Vocabulary", systemImage: "character.book.closed") }
                .tag(Page.vocabulary)
            Form {
                conversationSection
                accessSection
                aboutSection
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "gearshape") }
            .tag(Page.general)
        }
        .navigationTitle("Settings")
        .task { await model.refreshAccounts() }
        .onAppear { model.permissions.refresh() }
        .onChange(of: scenePhase) {
            if scenePhase == .active {
                model.permissions.refresh()
                Task { await model.refreshAccounts() }
            }
        }
    }

    // MARK: Pages

    /// Glossaries that teach recognition the meeting's words and let the model restore the misheard ones.
    private var vocabularySection: some View {
        Section {
            ForEach(model.glossaries.all) { glossary in
                Toggle(isOn: glossaryBinding(glossary.id)) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: glossary.title)
                            Text("\(glossary.terms.count) terms")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if !glossary.isBuiltIn {
                            Spacer()
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                model.glossaries.delete(glossary.id)
                                model.preferences.glossaries.remove(glossary.id)
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .help("Delete this glossary")
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("My terms")
                TextEditor(text: $model.preferences.customTerms)
                    .font(.callout.monospaced())
                    .frame(minHeight: 60, maxHeight: 120)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(alignment: .topLeading) {
                        if model.preferences.customTerms.isEmpty {
                            Text(verbatim: "Kubernetes | кубер, губерни\nPayments API")
                                .font(.callout.monospaced())
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .allowsHitTesting(false)
                        }
                    }
            }
            LabeledContent("Glossary files") {
                HStack(spacing: 8) {
                    Button("Import…", action: importGlossary)
                        .buttonStyle(.glass)
                        .help("Add a text or CSV file with one term per line")
                    Button("Show in Finder", action: showGlossaryFolder)
                        .buttonStyle(.glass)
                        .help("Glossary files can be added and edited in this folder")
                }
            }
            if let glossaryError {
                Label(glossaryError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } header: {
            Label("Vocabulary", systemImage: "character.book.closed")
        } footer: {
            footnote("Terms help speech recognition and let the model restore misheard words in hints and summaries. A file has one term per line; “Kubernetes | кубер, губерни” also says how the term may be misheard. Names and terms from the meeting notes are used too.")
        }
        .onAppear { model.glossaries.reload() }
    }

    private func glossaryBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { model.preferences.glossaries.contains(id) },
            set: { isOn in
                if isOn { model.preferences.glossaries.insert(id) } else { model.preferences.glossaries.remove(id) }
            }
        )
    }

    private func importGlossary() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.plainText, .commaSeparatedText, .text]
        panel.message = String(localized: "One term per line. After “|”, how the term may be misheard, comma-separated.")
        guard panel.runModal() == .OK else { return }
        glossaryError = nil
        for url in panel.urls {
            do {
                let glossary = try model.glossaries.importFile(url)
                model.preferences.glossaries.insert(glossary.id)
            } catch {
                glossaryError = error.localizedDescription
            }
        }
    }

    private func showGlossaryFolder() {
        guard let folder = model.glossaries.folder else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    private var meetingSection: some View {
        Section {
            Picker("Hints", selection: $model.preferences.hintMode) {
                ForEach(HintMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            Toggle("Hints on my questions too", isOn: $model.preferences.hintsOnOwnQuestions)
                .help("Suggest answers to questions you ask aloud as well, not only the other side's: for practice, or a meeting you lead.")
                .disabled(model.preferences.hintMode == .manual)
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
            footnote("Speech is recognized on this Mac. ⌃⌥Space in any app asks for a hint. Which model gives hints and writes summaries is chosen under Models.")
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

    private func footnote(_ text: LocalizedStringKey) -> some View {
        Footnote(text)
    }

    private func statusBadge(isOK: Bool, ok: String, missing: String) -> some View {
        StatusBadge(isOK: isOK, text: isOK ? ok : missing)
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
