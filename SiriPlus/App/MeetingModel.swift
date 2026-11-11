import AppKit
import Combine
import Foundation

struct MeetingHint: Identifiable, Equatable, Sendable {
    enum Kind: Sendable {
        case question
        case topic
        case manual

        var title: String {
            switch self {
            case .question: String(localized: "Answer to a question")
            case .topic: String(localized: "On the topic")
            case .manual: String(localized: "On request")
            }
        }
    }

    let id: UUID
    let kind: Kind
    /// The question that triggered the hint, if any.
    let question: String?
    let createdAt: Date
    var text = ""
    var isStreaming = true
    var failure: String?

    /// The model answers "—" when no hint is needed.
    var isEmptyAnswer: Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return trimmed.isEmpty
    }
}

@MainActor
final class MeetingModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case starting
        case running
    }

    struct Timing {
        /// Wait after the other side stops talking before treating the text as a finished question.
        var questionDelay: Duration = .milliseconds(1_200)
        /// New words needed before an automatic topic hint.
        var topicWords = 70
        /// Minimum seconds between automatic topic hints.
        var topicInterval: TimeInterval = 45
        /// How long the user may talk with nothing heard from the other side before the meeting screen says so.
        var silentOtherSideDelay: TimeInterval = 30
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var transcript = Transcript()
    @Published private(set) var hints: [MeetingHint] = []
    @Published private(set) var levels: [Speaker: Float] = [:]
    /// The call plays through speakers: the microphone hears the other side, and the transcript drops it as echo.
    @Published private(set) var playsAloud = false
    /// When the running meeting started, for the menu bar timer.
    private(set) var recordingSince: Date?
    @Published private(set) var sources: [MeetingAudioSource] = [.system]
    @Published var selectedSourceID = MeetingAudioSource.system.id
    @Published var notes = ""
    /// The user has been talking for a while and nothing has been heard from the other side:
    /// the audio source is probably wrong, or the call is not playing.
    @Published private(set) var missesOtherSide = false
    /// Files whose text is still being read into the notes.
    @Published private(set) var readingMaterials: [String] = []
    @Published var errorMessage: String?
    /// Receives every finished meeting that has a transcript.
    var onFinish: ((MeetingRecord) -> Void)?

    private let service: any MeetingService
    private let hintService: any HintService
    private let preferences: () -> AssistantPreferences
    /// The terms of the glossaries switched on in Settings.
    private let vocabulary: () -> [Glossary.Term]
    private let timing: Timing
    private var heardOtherSide = false
    /// Where a meeting's sound is saved; nil when this model never records.
    private let recordingURL: ((UUID) -> URL)?
    private var eventsTask: Task<Void, Never>?
    private var questionTask: Task<Void, Never>?
    private var hintTask: Task<Void, Never>?
    private var activeHintID: UUID?
    /// Characters of each turn's final text already answered with a question hint.
    private var answeredLength: [UUID: Int] = [:]
    private var wordsAtLastHint = 0
    private var lastHintAt = Date.distantPast

    init(
        service: any MeetingService,
        hintService: any HintService,
        timing: Timing = Timing(),
        recordingURL: ((UUID) -> URL)? = nil,
        vocabulary: @escaping () -> [Glossary.Term] = { [] },
        preferences: @escaping () -> AssistantPreferences
    ) {
        self.vocabulary = vocabulary
        self.service = service
        self.hintService = hintService
        self.timing = timing
        self.recordingURL = recordingURL
        self.preferences = preferences
    }

    var isRunning: Bool { phase == .running }

    // MARK: Materials

    /// Reads dropped, chosen or pasted files on this Mac and adds their text to the meeting notes.
    func addMaterials(_ urls: [URL]) {
        for url in urls {
            readMaterial(named: url.lastPathComponent) { locales in try await MaterialReader.text(from: url, locales: locales) }
        }
    }

    /// Adds what ⌘V brought into the notes: copied files, or the text on a copied picture.
    func addMaterial(_ pasted: PastedContent) {
        switch pasted {
        case .files(let urls):
            addMaterials(urls)
        case .image(let image):
            let name = String(localized: "Pasted image")
            guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                errorMessage = AttachmentError.unreadable(name).localizedDescription
                return
            }
            readMaterial(named: name) { locales in try await MaterialReader.text(from: cgImage, name: name, locales: locales) }
        }
    }

    private func readMaterial(named name: String, read: @escaping @Sendable ([Locale]) async throws -> String) {
        readingMaterials.append(name)
        let locales = preferences().speechLocales
        Task {
            do {
                let block = MaterialReader.block(name: name, text: try await read(locales))
                let current = notes.trimmingCharacters(in: .whitespacesAndNewlines)
                notes = current.isEmpty ? block : current + "\n\n" + block
            } catch {
                errorMessage = error.localizedDescription
            }
            if let index = readingMaterials.firstIndex(of: name) { readingMaterials.remove(at: index) }
        }
    }
    var latestHint: MeetingHint? { hints.last { !$0.isEmptyAnswer || $0.failure != nil } }
    var isHinting: Bool { activeHintID != nil }

    func refreshSources() {
        sources = MeetingAudioSource.available()
        // Follow the running call app unless the user picked another app that is still running.
        if selectedSourceID == MeetingAudioSource.system.id || !sources.contains(where: { $0.id == selectedSourceID }) {
            selectedSourceID = MeetingAudioSource.preferred(in: sources).id
        }
    }

    func start() async {
        guard phase == .idle else { return }
        let settings = preferences()
        let source = sources.first { $0.id == selectedSourceID } ?? .system
        phase = .starting
        errorMessage = nil
        transcript = Transcript()
        hints = []
        levels = [:]
        playsAloud = false
        missesOtherSide = false
        heardOtherSide = false
        answeredLength = [:]
        wordsAtLastHint = 0
        lastHintAt = Date()
        let startedAt = Date()
        recordingSince = startedAt
        // The meeting's id is known from the start, so its sound file can be named after it.
        let id = UUID()
        let audioURL = settings.recordsAudio ? recordingURL?(id) : nil

        do {
            let events = try await service.start(MeetingConfiguration(
                source: source,
                locales: settings.speechLocales,
                capturesMicrophone: settings.capturesMicrophone,
                contextualStrings: vocabulary().recognitionStrings(after: MeetingConfiguration.contextualStrings(from: notes)),
                recordingURL: audioURL
            ))
            guard phase == .starting else {
                await service.stop()
                return
            }
            phase = .running
            eventsTask = Task { [weak self] in
                do {
                    for try await event in events {
                        self?.handle(event)
                    }
                } catch {
                    self?.errorMessage = String(localized: "Listening stopped: \(error.localizedDescription)")
                }
                await self?.stop()
                // The stream ends after stopping flushed the last recognised text, so the transcript is complete here.
                self?.archive(id: id, startedAt: startedAt, audioURL: audioURL)
            }
        } catch {
            phase = .idle
            errorMessage = error.localizedDescription
        }
    }

    func stop() async {
        guard phase != .idle else { return }
        recordingSince = nil
        phase = .idle
        questionTask?.cancel()
        questionTask = nil
        levels = [:]
        playsAloud = false
        await service.stop()
        eventsTask = nil
    }

    /// Requests a hint right now, e.g. from the global shortcut.
    func askNow() {
        guard !transcript.isEmpty else { return }
        requestHint(.manual)
    }

    func clear() {
        guard phase == .idle else { return }
        cancelHint()
        transcript = Transcript()
        hints = []
        answeredLength = [:]
    }

    var transcriptText: String { transcript.recentText(characterLimit: .max, label: \.title) }

    /// "4:05" under an hour, "1:02:03" after.
    static func elapsedText(_ seconds: TimeInterval) -> String {
        let total = max(Int(seconds), 0)
        let (hours, minutes, secs) = (total / 3_600, total % 3_600 / 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    private func archive(id: UUID, startedAt: Date, audioURL: URL?) {
        // A meeting started again before the old stream ended has already replaced the transcript.
        guard phase == .idle, !transcript.isEmpty else {
            // Nothing is kept for a meeting without words, its sound included.
            if let audioURL { try? FileManager.default.removeItem(at: audioURL) }
            return
        }
        let turns = transcript.turns.map { turn in
            var turn = turn
            turn.finalText = turn.text
            turn.volatileText = ""
            return turn
        }
        let shown = hints.filter { !$0.isEmptyAnswer && $0.failure == nil }.map {
            SavedHint(createdAt: $0.createdAt, question: $0.question, text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        onFinish?(MeetingRecord(id: id, startedAt: startedAt, endedAt: Date(), turns: turns, notes: notes, hints: shown))
    }

    private func handle(_ event: MeetingEvent) {
        switch event {
        case .level(let speaker, let level):
            levels[speaker] = level
            if speaker == .them, level > 0.1 { hearOtherSide() }
        case .loudspeaker(let isLoud):
            playsAloud = isLoud
        case .recordingFailed(let message):
            errorMessage = String(localized: "The meeting audio was not saved. \(message)")
        case .segment(let segment):
            guard let turn = transcript.apply(segment), segment.isFinal else { return }
            let settings = preferences()
            let mode = settings.hintMode
            if segment.speaker == .them {
                hearOtherSide()
                if mode != .manual { scheduleQuestionCheck(turnID: turn.id, chunk: segment.text) }
            } else {
                noticeSilentOtherSide()
                if mode != .manual, settings.hintsOnOwnQuestions { scheduleQuestionCheck(turnID: turn.id, chunk: segment.text, own: true) }
            }
            if mode == .questionsAndTopic {
                considerTopicHint()
            }
        }
    }

    private func hearOtherSide() {
        heardOtherSide = true
        missesOtherSide = false
    }

    /// Half a minute into the meeting with the user talking and nothing from the other side.
    private func noticeSilentOtherSide() {
        guard !heardOtherSide, !missesOtherSide, let since = recordingSince,
              Date().timeIntervalSince(since) >= timing.silentOtherSideDelay else { return }
        missesOtherSide = true
    }

    private func scheduleQuestionCheck(turnID: UUID, chunk: String, own: Bool = false) {
        questionTask?.cancel()
        questionTask = Task { [weak self, delay = timing.questionDelay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.checkForQuestion(turnID: turnID, chunk: chunk, own: own)
        }
    }

    private func checkForQuestion(turnID: UUID, chunk: String, own: Bool = false) {
        // Still speaking: the next final result reschedules the check.
        guard let turn = transcript.turns.first(where: { $0.id == turnID }), turn.volatileText.isEmpty else { return }
        let answered = answeredLength[turnID] ?? 0
        let unanswered = String(turn.finalText.dropFirst(answered)).trimmingCharacters(in: .whitespaces)
        guard !unanswered.isEmpty,
              QuestionDetector.isLikelyQuestion(chunk) || QuestionDetector.isLikelyQuestion(unanswered) else { return }
        answeredLength[turnID] = turn.finalText.count
        let words = unanswered.split(separator: " ").suffix(40).joined(separator: " ")
        requestHint(own ? .ownQuestion(words) : .question(words))
    }

    private func considerTopicHint() {
        guard activeHintID == nil,
              transcript.finalWordCount - wordsAtLastHint >= timing.topicWords,
              Date().timeIntervalSince(lastHintAt) >= timing.topicInterval else { return }
        requestHint(.topic)
    }

    private func requestHint(_ trigger: HintRequest.Trigger) {
        let kind: MeetingHint.Kind
        let question: String?
        switch trigger {
        case .question(let text), .ownQuestion(let text): (kind, question) = (.question, text)
        case .topic: (kind, question) = (.topic, nil)
        case .manual: (kind, question) = (.manual, nil)
        }
        // A newer question or an explicit request replaces the hint being written.
        cancelHint()

        let settings = preferences()
        guard let selection = settings.hintSelection else {
            // Said once in the hints column, not again for every question.
            if hints.last?.failure != ModelErrorReport.noModel(for: .hints).summary {
                var hint = MeetingHint(id: UUID(), kind: kind, question: question, createdAt: Date())
                hint.isStreaming = false
                hint.failure = ModelErrorReport.noModel(for: .hints).summary
                hints.append(hint)
            }
            return
        }
        let request = HintRequest(
            trigger: trigger,
            transcript: transcript.recentText(characterLimit: 6_000),
            notes: notes,
            previousHints: hints.filter { !$0.isEmptyAnswer && $0.failure == nil }.suffix(3).map(\.text),
            selection: selection,
            vocabulary: vocabulary().promptText
        )
        let hint = MeetingHint(id: UUID(), kind: kind, question: question, createdAt: Date())
        hints.append(hint)
        activeHintID = hint.id
        wordsAtLastHint = transcript.finalWordCount
        lastHintAt = Date()

        hintTask = Task { [weak self, hintService] in
            do {
                for try await text in hintService.hint(for: request) {
                    self?.updateHint(hint.id) { $0.text += text }
                }
                self?.finishHint(hint.id, failure: nil)
            } catch is CancellationError {
                self?.finishHint(hint.id, failure: nil)
            } catch {
                self?.finishHint(hint.id, failure: ModelErrorReport(error).compactText)
            }
        }
    }

    private func cancelHint() {
        hintTask?.cancel()
        hintTask = nil
        if let activeHintID { finishHint(activeHintID, failure: nil) }
    }

    private func updateHint(_ id: UUID, _ change: (inout MeetingHint) -> Void) {
        guard let index = hints.firstIndex(where: { $0.id == id }) else { return }
        change(&hints[index])
    }

    private func finishHint(_ id: UUID, failure: String?) {
        if activeHintID == id { activeHintID = nil }
        guard let index = hints.firstIndex(where: { $0.id == id }) else { return }
        hints[index].isStreaming = false
        hints[index].failure = failure
        // Drop "no hint needed" answers and hints cancelled before any text arrived.
        if failure == nil, hints[index].isEmptyAnswer {
            hints.remove(at: index)
        }
    }
}
