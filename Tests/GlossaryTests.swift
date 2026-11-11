import Foundation
import Testing
@testable import SiriPlusCore

struct GlossaryTests {
    @Test func filesNameTermsAndMishearings() {
        let text = """
        # title: IT and development
        # title.ru: IT и разработка
        # A comment
        Kubernetes | кубер, губерни
        Docker
        docker
        PostgreSQL;database;notes

        """
        let english = Glossary.parse(text, id: "it", language: "en")
        #expect(english.title == "IT and development")
        #expect(Glossary.parse(text, id: "it", language: "ru").title == "IT и разработка")
        #expect(english.terms == [
            .init(text: "Kubernetes", soundsLike: ["кубер", "губерни"]),
            .init(text: "Docker"),
            .init(text: "PostgreSQL"),
        ])
        #expect(Glossary.parse("Term", id: "file:mine").title == "file:mine")
    }

    @Test func recognitionTakesTheNotesFirstWithinTheLimit() {
        let terms: [Glossary.Term] = [.init(text: "Kubernetes"), .init(text: "Docker"), .init(text: "Kafka")]
        #expect(terms.recognitionStrings(after: ["Acme", "kubernetes"]) == ["Acme", "kubernetes", "Docker", "Kafka"])
        #expect(terms.recognitionStrings(after: ["Acme"], limit: 2) == ["Acme", "Kubernetes"])
    }

    @Test func promptListsMishearingsThenTheOtherTerms() {
        let terms: [Glossary.Term] = [.init(text: "Kubernetes", soundsLike: ["кубер", "губерни"]), .init(text: "Docker")]
        #expect(terms.promptText == "Often misheard (heard → meant): кубер, губерни → Kubernetes\nOther terms that may come up: Docker")
        #expect([Glossary.Term]().promptText.isEmpty)
    }

    @Test func builtInGlossariesParse() throws {
        let folder = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "SiriPlus/Resources/Glossaries")
        for name in ["it", "business"] {
            let glossary = Glossary.parse(try String(contentsOf: folder.appending(path: "\(name).txt"), encoding: .utf8), id: name, language: "ru")
            #expect(!glossary.title.isEmpty && glossary.title != name)
            #expect(glossary.terms.count >= 30)
            #expect(glossary.terms.count <= [Glossary.Term].recognitionLimit)
        }
        let it = Glossary.parse(try String(contentsOf: folder.appending(path: "it.txt"), encoding: .utf8), id: "it")
        // The words from the recorded meeting that recognition got wrong.
        let misheard = Dictionary(uniqueKeysWithValues: it.terms.map { ($0.text, $0.soundsLike) })
        #expect(misheard["Kubernetes"]?.contains("губерни") == true)
        #expect(misheard["garbage collector"]?.contains("горбач коллектор") == true)
        #expect(misheard["React Native"]?.contains("наряд ныть") == true)
        #expect(misheard["Flutter"]?.contains("flat") == true)
    }

    @Test func promptsCarryTheVocabulary() {
        let hint = AssistantPrompts.hint(HintRequest(trigger: .ownQuestion("как работает garbage collector"), transcript: "", notes: "",
                                                     previousHints: [], selection: ModelSelection(), vocabulary: "Other terms that may come up: Go"))
        #expect(hint.system.contains("<vocabulary>\nOther terms that may come up: Go\n</vocabulary>"))
        #expect(hint.turns[0].text.contains("The user asked aloud: \"как работает garbage collector\""))
        let summary = AssistantPrompts.summary(SummaryRequest(transcript: "Me: губерни", notes: "", selection: ModelSelection(), vocabulary: "x → Kubernetes"))
        #expect(summary.system.contains("<vocabulary>\nx → Kubernetes\n</vocabulary>"))
        #expect(!AssistantPrompts.summary(SummaryRequest(transcript: "", notes: "", selection: ModelSelection())).system.contains("<vocabulary>"))
    }

    @Test func safariCallsIncludeWebKitAudio() {
        #expect(MeetingAudioSource.audioHelpers(of: "com.apple.Safari") == ["com.apple.WebKit."])
        #expect(MeetingAudioSource.audioHelpers(of: "com.google.Chrome").isEmpty)
    }
}

@MainActor
struct GlossaryLibraryTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "glossaries-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func importsFilesAndCombinesActiveTerms() throws {
        let bundled = try folder()
        try "# title: Built in\nKubernetes | губерни".write(to: bundled.appending(path: "it.txt"), atomically: true, encoding: .utf8)
        let imported = try folder()
        let library = GlossaryLibrary(bundleFolder: bundled, folder: imported)
        #expect(library.builtIn.map(\.id) == ["it"])
        #expect(library.imported.isEmpty)

        let source = try folder().appending(path: "Team.csv")
        try "term,comment\nAcme Pay,our product\nZed,codename".write(to: source, atomically: true, encoding: .utf8)
        let glossary = try library.importFile(source)
        #expect(glossary.id == "file:Team")
        #expect(glossary.terms.map(\.text) == ["term", "Acme Pay", "Zed"])
        #expect(FileManager.default.fileExists(atPath: imported.appending(path: "Team.txt").path))

        var preferences = AssistantPreferences(models: [.starter])
        preferences.glossaries = ["it", "file:Team"]
        preferences.customTerms = "Siri+ | сири плюс"
        #expect(library.activeTerms(preferences).map(\.text) == ["Siri+", "Kubernetes", "term", "Acme Pay", "Zed"])
        preferences.glossaries = []
        #expect(library.activeTerms(preferences).map(\.text) == ["Siri+"])

        library.delete("file:Team")
        #expect(library.imported.isEmpty)
        // Built-in glossaries cannot be deleted.
        library.delete("it")
        #expect(library.builtIn.count == 1)
    }

    @Test func emptyFilesAreRefused() throws {
        let library = GlossaryLibrary(bundleFolder: nil, folder: try folder())
        let source = try folder().appending(path: "empty.txt")
        try "# nothing here\n\n".write(to: source, atomically: true, encoding: .utf8)
        #expect(throws: GlossaryError.empty("empty.txt")) { try library.importFile(source) }
    }
}

@MainActor
struct MeetingVocabularyTests {
    private func makeMeeting(
        own: Bool = false,
        timing: MeetingModel.Timing = MeetingModel.Timing(questionDelay: .milliseconds(10), silentOtherSideDelay: 0)
    ) -> (MeetingModel, FakeMeetingService, ScriptedHints) {
        let service = FakeMeetingService()
        let hints = ScriptedHints()
        let terms: [Glossary.Term] = [.init(text: "Kubernetes", soundsLike: ["губерни"])]
        let meeting = MeetingModel(service: service, hintService: hints, timing: timing, vocabulary: { terms }) {
            AssistantPreferences(models: [.starter], hintsOnOwnQuestions: own, hintMode: .questions)
        }
        return (meeting, service, hints)
    }

    @Test func recognitionAndHintsGetTheGlossary() async throws {
        let (meeting, service, hints) = makeMeeting()
        meeting.notes = "Agenda: Acme Pay launch"
        await meeting.start()
        #expect(service.configuration?.contextualStrings == ["Agenda", "Acme", "Pay", "Kubernetes"])
        service.send(.segment(.init(speaker: .them, text: "как вы работаете с губерни", isFinal: true, timestamp: Date())))
        try await eventually { meeting.hints.first?.isStreaming == false }
        #expect(hints.requests.first?.vocabulary == "Often misheard (heard → meant): губерни → Kubernetes")
        await meeting.stop()
    }

    @Test func ownQuestionsGetHintsWhenAsked() async throws {
        let (silent, silentService, silentHints) = makeMeeting(own: false)
        await silent.start()
        silentService.send(.segment(.init(speaker: .me, text: "как работает garbage collector в go", isFinal: true, timestamp: Date())))
        try await Task.sleep(for: .milliseconds(80))
        #expect(silentHints.requests.isEmpty)
        await silent.stop()

        let (meeting, service, hints) = makeMeeting(own: true)
        await meeting.start()
        service.send(.segment(.init(speaker: .me, text: "как работает garbage collector в go", isFinal: true, timestamp: Date())))
        try await eventually { meeting.hints.first?.isStreaming == false }
        #expect(hints.requests.first?.trigger == .ownQuestion("как работает garbage collector в go"))
        await meeting.stop()
    }

    @Test func aSilentOtherSideIsReported() async throws {
        let (meeting, service, _) = makeMeeting()
        await meeting.start()
        service.send(.segment(.init(speaker: .me, text: "коллеги вы меня слышите", isFinal: true, timestamp: Date())))
        try await eventually { meeting.missesOtherSide }
        service.send(.level(.them, 0.6))
        try await eventually { !meeting.missesOtherSide }
        // Once they were heard, a pause on their side is not reported.
        service.send(.segment(.init(speaker: .me, text: "продолжим", isFinal: true, timestamp: Date())))
        try await Task.sleep(for: .milliseconds(50))
        #expect(!meeting.missesOtherSide)
        await meeting.stop()
    }

    @Test func hintsAreKeptWithTheMeeting() async throws {
        let (meeting, service, _) = makeMeeting()
        var saved: MeetingRecord?
        meeting.onFinish = { saved = $0 }
        await meeting.start()
        service.send(.segment(.init(speaker: .them, text: "какой у вас опыт с kubernetes", isFinal: true, timestamp: Date())))
        try await eventually { meeting.hints.first?.isStreaming == false }
        await meeting.stop()
        try await eventually { saved != nil }
        let record = try #require(saved)
        #expect(record.hints.map(\.text) == ["Скажи про три года опыта."])
        #expect(record.hints.first?.question == "какой у вас опыт с kubernetes")
        #expect(record.markdown(includingTranscript: true).contains("Скажи про три года опыта."))
        // Saved meetings come back with their hints; older ones without any.
        let decoded = try JSONDecoder().decode(MeetingRecord.self, from: JSONEncoder().encode(record))
        #expect(decoded.hints == record.hints)
    }
}
