import AVFoundation
import Foundation
import Testing
@testable import SiriPlusCore

@Suite
struct MeetingSummaryTests {
    @Test func parsesSections() {
        let summary = MeetingSummary(parsing: """
        **TITLE:** «Перенос сервиса в облако»
        PARTICIPANTS: Анна, Олег, —
        SUMMARY:
        - Решили переезжать в ноябре
        - Олег готовит план
        """)
        #expect(summary.title == "Перенос сервиса в облако")
        #expect(summary.participants == ["Анна", "Олег"])
        #expect(summary.summary == "- Решили переезжать в ноябре\n- Олег готовит план")
    }

    @Test func parsesTasks() {
        let summary = MeetingSummary(parsing: """
        TITLE: Планёрка
        SUMMARY:
        - Обсудили переезд
        TASKS:
        - Олег | прислать план | до пятницы
        - — | согласовать бюджет | —
        - написать в чат
        """)
        #expect(summary.summary == "- Обсудили переезд")
        #expect(summary.tasks.map(\.owner) == ["Олег", "", ""])
        #expect(summary.tasks.map(\.text) == ["прислать план", "согласовать бюджет", "написать в чат"])
        #expect(summary.tasks.map(\.due) == ["до пятницы", "", ""])
        #expect(summary.tasks[0].line == "Олег: прислать план · до пятницы")
        #expect(MeetingSummary(parsing: "SUMMARY:\n- Итог\nTASKS:\n—").tasks.isEmpty)
    }

    @Test func freeTextBecomesSummary() {
        let summary = MeetingSummary(parsing: "Обсудили сроки.\nPARTICIPANTS: —")
        #expect(summary.title.isEmpty)
        #expect(summary.participants.isEmpty)
        #expect(summary.summary == "Обсудили сроки.")
    }
}

@Suite @MainActor
struct MeetingHistoryTests {
    private let reply = "TITLE: Миграция\nPARTICIPANTS: Анна\nSUMMARY:\n- Переезд в ноябре"

    @Test func finishedMeetingIsSavedAndSummarized() async throws {
        let (meeting, service, hints) = makeMeeting()
        let store = temporaryStore()
        let history = MeetingHistory(store: store, summaries: hints) { AssistantPreferences() }
        meeting.onFinish = { history.add($0) }
        hints.summaryReply = reply

        meeting.notes = "Проект: миграция"
        await meeting.start()
        service.send(.segment(.init(speaker: .them, text: "мы переезжаем в ноябре", isFinal: true, timestamp: Date())))
        service.send(.segment(.init(speaker: .me, text: "отлично", isFinal: false, timestamp: Date())))
        await meeting.stop()
        try await eventually { history.records.first?.summary.isEmpty == false }

        let record = try #require(history.records.first)
        #expect(record.title == "Миграция")
        #expect(record.participants == ["Анна"])
        #expect(record.turns.map(\.text) == ["мы переезжаем в ноябре", "отлично"])
        #expect(record.turns.allSatisfy { $0.volatileText.isEmpty })
        #expect(hints.summaryRequests.first?.transcript == "Them: мы переезжаем в ноябре\nMe: отлично")
        #expect(hints.summaryRequests.first?.notes == "Проект: миграция")
        #expect(try store.load() == history.records)
    }

    @Test func silentMeetingIsNotSaved() async throws {
        let (meeting, _, hints) = makeMeeting()
        let history = MeetingHistory(store: temporaryStore(), summaries: hints) { AssistantPreferences() }
        meeting.onFinish = { history.add($0) }
        await meeting.start()
        await meeting.stop()
        try await Task.sleep(for: .milliseconds(50))
        #expect(history.records.isEmpty)
    }

    @Test func titleSetByUserSurvivesNewSummary() async throws {
        let hints = ScriptedHints()
        hints.summaryReply = reply
        let store = temporaryStore()
        let history = MeetingHistory(store: store, summaries: hints) { AssistantPreferences() }
        history.add(record())
        try await eventually { history.records[0].summary == "- Переезд в ноябре" && history.summarizing.isEmpty }

        let id = history.records[0].id
        history.rename(id, to: "  Планёрка  ")
        hints.summaryReply = "TITLE: Другое\nSUMMARY:\n- Новое"
        history.summarize(id)
        try await eventually { history.records[0].summary == "- Новое" }

        #expect(history.records[0].title == "Планёрка")
        #expect(try store.load()[0].title == "Планёрка")
    }

    @Test func deletedMeetingIsRemovedFromDisk() throws {
        let store = temporaryStore()
        let history = MeetingHistory(store: store, summaries: ScriptedHints()) { AssistantPreferences() }
        history.add(record())
        history.delete(history.records[0].id)
        #expect(try store.load().isEmpty)
    }

    @Test func unreadableFileIsSetAsideNotOverwritten() throws {
        let store = temporaryStore()
        try FileManager.default.createDirectory(at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: store.url)

        let history = MeetingHistory(store: store, summaries: ScriptedHints()) { AssistantPreferences() }
        #expect(history.records.isEmpty)
        #expect(history.errorMessage != nil)
        let files = try FileManager.default.contentsOfDirectory(atPath: store.url.deletingLastPathComponent().path)
        #expect(files.contains { $0.hasPrefix("meetings-unreadable-") })
    }

    @Test func toggledTaskIsSaved() async throws {
        let hints = ScriptedHints()
        hints.summaryReply = "SUMMARY:\n- Итог\nTASKS:\n- Олег | план | пятница"
        let store = temporaryStore()
        let history = MeetingHistory(store: store, summaries: hints) { AssistantPreferences() }
        history.add(record())
        try await eventually { history.records[0].tasks.count == 1 }

        history.toggleTask(history.records[0].tasks[0].id, in: history.records[0].id)
        #expect(try store.load()[0].tasks[0].isDone)
    }

    @Test func oldMeetingsKeepThemselvesAndExpiredOnesAreDeleted() throws {
        let store = temporaryStore()
        var old = record(endedDaysAgo: 40)
        old.title = "Старый"
        try store.save([record(endedDaysAgo: 2), old])

        var preferences = AssistantPreferences()
        let history = MeetingHistory(store: store, summaries: ScriptedHints()) { preferences }
        #expect(history.records.count == 2)

        preferences.historyRetentionDays = 30
        history.removeExpired()
        #expect(history.records.count == 1)
        #expect(try store.load().map(\.title) == [""])
    }

    @Test func meetingsSavedWithoutTasksStillLoad() throws {
        let json = """
        [{"id":"\(UUID().uuidString)","startedAt":0,"endedAt":60,"title":"Созвон","summary":"","participants":[],
          "turns":[],"notes":""}]
        """
        let records = try JSONDecoder().decode([MeetingRecord].self, from: Data(json.utf8))
        #expect(records.first?.title == "Созвон")
        #expect(records.first?.tasks == [])
    }

    @Test func searchLooksEverywhereIgnoringCase() {
        var meeting = record()
        meeting.title = "Планёрка"
        meeting.participants = ["Анна"]
        meeting.tasks = [MeetingTask(owner: "Олег", text: "бюджет")]
        for query in ["планерка", "АННА", "бюджет", "ПРИВЕТ", ""] {
            #expect(meeting.matches(query), "\(query)")
        }
        #expect(!meeting.matches("kubernetes"))
    }

    @Test func markdownHasSectionsAndOptionalTranscript() {
        var meeting = record()
        meeting.title = "Планёрка"
        meeting.summary = "- Итог"
        meeting.tasks = [MeetingTask(owner: "Олег", text: "план", isDone: true)]
        let short = meeting.markdown(includingTranscript: false)
        #expect(short.hasPrefix("# Планёрка\n"))
        #expect(short.contains("- Итог"))
        #expect(short.contains("- [x] Олег: план"))
        #expect(!short.contains("привет"))
        #expect(meeting.markdown(includingTranscript: true).contains("привет"))
    }

    private func record(endedDaysAgo days: Double = 0) -> MeetingRecord {
        let end = Date().addingTimeInterval(-days * 86_400)
        return MeetingRecord(
            startedAt: end.addingTimeInterval(-600),
            endedAt: end,
            turns: [TranscriptTurn(id: UUID(), speaker: .them, startedAt: end, updatedAt: end, finalText: "привет", volatileText: "")],
            notes: ""
        )
    }

    private func temporaryStore() -> MeetingHistoryStore {
        MeetingHistoryStore(url: FileManager.default.temporaryDirectory.appending(path: "siriplus-\(UUID().uuidString)/meetings.json"))
    }

    private func makeMeeting() -> (MeetingModel, FakeMeetingService, ScriptedHints) {
        let service = FakeMeetingService()
        let hints = ScriptedHints()
        let meeting = MeetingModel(service: service, hintService: hints, timing: .init(questionDelay: .milliseconds(10))) {
            AssistantPreferences(hintMode: .manual)
        }
        return (meeting, service, hints)
    }
}

@Suite
struct HistoryExportTests {
    @Test func chatMarkdownNamesAuthorsAndAttachments() {
        let chat = ChatConversation(messages: [
            ChatMessage(role: .user, text: "Что в отчёте?", imageJPEG: Data([1]), attachments: [ChatAttachment(name: "отчёт.pdf", content: .text("…"))]),
            ChatMessage(role: .assistant, text: "Выручка выросла."),
        ])
        let markdown = chat.markdown(meetingTitle: "Планёрка")
        #expect(markdown.hasPrefix("# Что в отчёте?\n"))
        #expect(markdown.contains("Планёрка"))
        #expect(markdown.contains("### Siri+ · "))
        #expect(markdown.contains("отчёт.pdf, Screenshot"))
        #expect(markdown.contains("Выручка выросла."))
        // The text of attached documents stays out of the export.
        #expect(!markdown.contains("<attachment"))
    }

    @Test func writesMeetingsChatsAndAnIndex() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "siriplus-export-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var meeting = MeetingRecord(
            startedAt: start, endedAt: start.addingTimeInterval(1_800),
            turns: [TranscriptTurn(id: UUID(), speaker: .them, startedAt: start, updatedAt: start, finalText: "привет", volatileText: "")],
            notes: "Повестка: бюджет"
        )
        meeting.title = "Бюджет: Q4 / план"
        meeting.summary = "- Бюджет утверждён\n- Олег пишет план"
        var chat = ChatConversation(messages: [ChatMessage(role: .user, text: "Что решили?")])
        chat.meetingID = meeting.id

        let folder = try HistoryExport.write(meetings: [meeting], chats: [chat], into: directory, now: start)
        let index = try String(contentsOf: folder.appending(path: "index.md"), encoding: .utf8)
        let meetings = try FileManager.default.contentsOfDirectory(atPath: folder.appending(path: "Meetings").path)
        let chats = try FileManager.default.contentsOfDirectory(atPath: folder.appending(path: "Chats").path)
        #expect(meetings.count == 1 && chats.count == 1)
        let meetingFile = try #require(meetings.first)
        #expect(meetingFile.hasSuffix("Бюджет Q4 план.md"))
        #expect(index.contains("Бюджет утверждён"))
        #expect(index.contains("(<Meetings/\(meetingFile.precomposedStringWithCanonicalMapping)>)"))
        let meetingText = try String(contentsOf: folder.appending(path: "Meetings/\(meetingFile)"), encoding: .utf8)
        #expect(meetingText.contains("Повестка: бюджет"))
        #expect(meetingText.contains("привет"))
        let chatText = try String(contentsOf: folder.appending(path: "Chats/\(chats[0])"), encoding: .utf8)
        #expect(chatText.contains("Бюджет: Q4 / план"))

        // A recorded meeting brings its sound along, linked from its Markdown.
        let audio = directory.appending(path: "source.m4a")
        try Data([1, 2, 3]).write(to: audio)
        let withAudio = try HistoryExport.write(meetings: [meeting], chats: [], into: directory, now: start) { $0 == meeting.id ? audio : nil }
        let exported = try FileManager.default.contentsOfDirectory(atPath: withAudio.appending(path: "Meetings").path).sorted()
        #expect(exported.count == 2 && exported[0].hasSuffix(".m4a") && exported[1].hasSuffix(".md"))
        let linked = try String(contentsOf: withAudio.appending(path: "Meetings/\(exported[1])"), encoding: .utf8)
        #expect(linked.contains("(<\(exported[0].precomposedStringWithCanonicalMapping)>)"))

        // A second export goes into its own folder.
        let second = try HistoryExport.write(meetings: [], chats: [], into: directory, now: start)
        #expect(second != folder)
        #expect(second.lastPathComponent.hasSuffix(" 3"))
    }

    @Test func fileNamesAreSafe() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let name = HistoryExport.fileName(date, "  a/b:c*?\nd.  ")
        #expect(!name.contains("/") && !name.contains(":") && !name.contains("\n"))
        #expect(name.hasSuffix(" a b c d"))
        #expect(HistoryExport.fileName(date, String(repeating: "x", count: 300)).count < 100)
    }
}

@Suite
struct MeetingRecordingTests {
    private let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!

    /// `seconds` of a tone, as the capture delivers it.
    private func tone(_ seconds: Double, frequency: Float = 440) -> AVAudioPCMBuffer {
        let frames = AVAudioFrameCount(seconds * format.sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for index in 0..<Int(frames) {
            buffer.floatChannelData![0][index] = 0.3 * sin(2 * .pi * frequency * Float(index) / Float(format.sampleRate))
        }
        return buffer
    }

    private func feed(_ recorder: MeetingRecorder, _ speaker: Speaker, from start: Double, to end: Double, base: Double) {
        var time = start
        while time < end - 0.001 {
            recorder.append(tone(0.1), of: speaker, at: CMTime(seconds: base + time, preferredTimescale: 48_000))
            time += 0.1
        }
    }

    @Test func mixesBothVoicesIntoOneFileOnOneClock() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "siriplus-\(UUID().uuidString)/meeting.m4a")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let recorder = try MeetingRecorder()
        // The capture clock does not start at zero. They speak, pause for a second, speak again; I join later.
        let base = 81_234.5
        feed(recorder, .them, from: 0, to: 1, base: base)
        feed(recorder, .me, from: 0.5, to: 1.5, base: base)
        feed(recorder, .them, from: 2, to: 3, base: base)
        try await recorder.finish(to: url)

        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - 3) < 0.15, "duration \(duration)")
        #expect(try await asset.loadTracks(withMediaType: .audio).count == 1)
    }

    @Test func oneVoiceIsSavedAsIsAndSilenceSavesNothing() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "siriplus-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let single = try MeetingRecorder()
        feed(single, .them, from: 0, to: 1, base: 10)
        try await single.finish(to: directory.appending(path: "one.m4a"))
        let duration = try await AVURLAsset(url: directory.appending(path: "one.m4a")).load(.duration).seconds
        #expect(abs(duration - 1) < 0.1)

        try await MeetingRecorder().finish(to: directory.appending(path: "none.m4a"))
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "none.m4a").path))
    }

    @Test @MainActor func recordingIsNamedAfterTheMeetingAndDeletedWithIt() async throws {
        let store = MeetingHistoryStore(url: FileManager.default.temporaryDirectory.appending(path: "siriplus-\(UUID().uuidString)/meetings.json"))
        defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        let service = FakeMeetingService()
        let hints = ScriptedHints()
        var recordsAudio = false
        let meeting = MeetingModel(service: service, hintService: hints, recordingURL: store.recordingURL(for:)) {
            AssistantPreferences(hintMode: .manual, recordsAudio: recordsAudio)
        }
        let history = MeetingHistory(store: store, summaries: hints) { AssistantPreferences() }
        meeting.onFinish = { history.add($0) }

        await meeting.start()
        #expect(service.configuration?.recordingURL == nil)
        await meeting.stop()

        recordsAudio = true
        await meeting.start()
        let url = try #require(service.configuration?.recordingURL)
        // The service writes the file when it stops.
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1]).write(to: url)
        service.send(.segment(.init(speaker: .them, text: "привет", isFinal: true, timestamp: Date())))
        await meeting.stop()
        try await eventually { !history.records.isEmpty }
        let record = try #require(history.records.first)
        #expect(store.recordingURL(for: record.id) == url)
        #expect(history.recording(for: record.id) == url)

        history.delete(record.id)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
