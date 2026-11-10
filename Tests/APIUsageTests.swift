import AppKit
import Foundation
import Testing
@testable import SiriPlusCore

struct APIUsageTests {
    @Test func claudeStreamReportsInputAndOutputTokens() throws {
        var decoder = ClaudeStreamDecoder()
        let start = #"data: {"type":"message_start","message":{"usage":{"input_tokens":200,"cache_creation_input_tokens":1000,"cache_read_input_tokens":3000,"output_tokens":1}}}"#
        _ = try decoder.consume(line: start)
        _ = try decoder.finish()
        _ = try decoder.consume(line: #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":420}}"#)
        _ = try decoder.finish()
        #expect(decoder.usage == TokenUsage(cacheHitTokens: 3000, cacheMissTokens: 200, cacheWriteTokens: 1000, outputTokens: 420))
    }

    @Test func responsesStreamReportsUsage() throws {
        var decoder = ResponsesStreamDecoder()
        let line = #"data: {"type":"response.completed","response":{"usage":{"input_tokens":1000,"input_tokens_details":{"cached_tokens":600},"output_tokens":80,"output_tokens_details":{"reasoning_tokens":30}}}}"#
        #expect(try decoder.consume(line: line) == .finished)
        #expect(decoder.usage == TokenUsage(cacheHitTokens: 600, cacheMissTokens: 400, outputTokens: 80, reasoningTokens: 30))
    }

    @Test func claudeCostUsesListPrices() throws {
        // Opus 5.5: $4 input, $5 cache write, $0.20 cache read, $20 output per million tokens.
        let usage = TokenUsage(cacheHitTokens: 1_000_000, cacheMissTokens: 1_000_000, cacheWriteTokens: 1_000_000, outputTokens: 1_000_000)
        let cost = try #require(APIPricing.cost(of: usage, provider: .claude, model: "claude-opus-5-5"))
        #expect(abs(cost - 29.2) < 0.000_1)
        #expect(APIPricing.cost(of: usage, provider: .claude, model: "claude-unknown") == nil)
        #expect(APIPricing.cost(of: usage, provider: .openAI, model: "gpt-6-luna") == nil)
        #expect(APIPricing.cost(of: usage, provider: .custom, model: "llama3.2") == nil)
    }

    @Test func ledgersKeepEachProviderApart() {
        let ledgers = UsageLedgers(directory: nil)
        ledgers.record(TokenUsage(cacheMissTokens: 10, outputTokens: 5), provider: .claude, model: "claude-haiku-5-5")
        ledgers.record(TokenUsage(cacheMissTokens: 10, outputTokens: 5), provider: .custom, model: "llama3.2")
        #expect(ledgers[.claude].days.first?.requests == 1)
        #expect(ledgers[.claude].days.first?.cost ?? 0 > 0)
        #expect(ledgers[.custom].days.first?.cost == 0)
        #expect(ledgers[.deepSeek].days.isEmpty)
    }

    @Test func serverAddressesAreNormalized() {
        #expect(ChatCompletionsClient.normalizedBase("localhost:11434")?.absoluteString == "http://localhost:11434/v1")
        #expect(ChatCompletionsClient.normalizedBase("http://127.0.0.1:1234/")?.absoluteString == "http://127.0.0.1:1234/v1")
        #expect(ChatCompletionsClient.normalizedBase("https://openrouter.ai/api/v1")?.absoluteString == "https://openrouter.ai/api/v1")
        #expect(ChatCompletionsClient.normalizedBase("api.groq.com/openai/v1")?.absoluteString == "https://api.groq.com/openai/v1")
        #expect(ChatCompletionsClient.normalizedBase("") == nil)
        #expect(ChatCompletionsClient.normalizedBase("ftp://example.com") == nil)
    }

    @Test func otherServersGetAPlainRequest() throws {
        let prompt = PreparedPrompt(system: "Be brief.", turns: [.init(role: .user, text: "Hi")], effort: "high", maxTokens: 4_000)
        let body = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(ChatCompletionsRequest(prompt: prompt, model: "llama3.2", flavor: .generic))) as? [String: Any])
        #expect(body["model"] as? String == "llama3.2")
        #expect(body["max_tokens"] == nil)
        #expect(body["reasoning_effort"] == nil)
        #expect(body["thinking"] == nil)
        #expect(body["stream"] as? Bool == true)
        let models = try ChatCompletionsClient.parseModels(Data(#"{"data":[{"id":"qwen3:8b"},{"id":"llama3.2"}]}"#.utf8), flavor: .generic)
        #expect(models.map(\.id) == ["llama3.2", "qwen3:8b"])
        #expect(models.allSatisfy { $0.efforts == [] })
    }

    @Test func aModelChosenForHintsKeepsItsEffortLive() async throws {
        let backend = EffortBackend()
        let service = CloudAssistantService(claudeAPI: backend, claudeCode: backend, openAIAPI: backend, chatGPT: backend, deepSeek: backend)
        func hint(_ selection: ModelSelection) async throws -> String {
            var text = ""
            for try await part in service.hint(for: HintRequest(trigger: .manual, transcript: "", notes: "", previousHints: [], selection: selection)) {
                text += part
            }
            return text
        }
        let main = ModelSelection(provider: .deepSeek, deepSeekEffort: "max")
        // The model above thinks deeply in chats, but hints stay light.
        #expect(try await hint(main) == "low")
        // A model chosen for hints sends its own level, "no thinking" included; "Automatic" stays light.
        #expect(try await hint(main.replacing(with: HintModelChoice(provider: .deepSeek, effort: "none"))) == "none")
        #expect(try await hint(main.replacing(with: HintModelChoice(provider: .deepSeek))) == "low")
    }
}

@MainActor
struct MaterialTests {
    @Test func textFilesAreAddedToTheNotes() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "agenda-\(UUID().uuidString).txt")
        try "1. Release date\n2. Payments API".write(to: url, atomically: true, encoding: .utf8)
        let meeting = MeetingModel(service: FakeMeetingService(), hintService: ControlledAssistant()) { AssistantPreferences() }
        meeting.notes = "Ask about the budget"
        meeting.addMaterials([url])
        #expect(meeting.readingMaterials == [url.lastPathComponent])
        try await eventually { meeting.readingMaterials.isEmpty }
        #expect(meeting.notes == "Ask about the budget\n\n— \(url.lastPathComponent) —\n1. Release date\n2. Payments API")
    }

    @Test func textOnAPictureIsRecognized() async throws {
        let image = NSImage(size: NSSize(width: 900, height: 200), flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            ("Release on March 28" as NSString).draw(at: NSPoint(x: 30, y: 70), withAttributes: [.font: NSFont.systemFont(ofSize: 64), .foregroundColor: NSColor.black])
            return true
        }
        let cgImage = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let text = try await MaterialReader.text(from: cgImage, name: "slide.png", locales: [Locale(identifier: "en-US")])
        #expect(text.contains("March 28"))
    }

    @Test func unsupportedFilesReportAnError() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "blob-\(UUID().uuidString).zip")
        try Data([0x50, 0x4B, 0x03, 0x04, 0xFF, 0xFE]).write(to: url)
        let meeting = MeetingModel(service: FakeMeetingService(), hintService: ControlledAssistant()) { AssistantPreferences() }
        meeting.addMaterials([url])
        try await eventually { meeting.readingMaterials.isEmpty }
        #expect(meeting.notes.isEmpty)
        #expect(meeting.errorMessage != nil)
    }
}

private struct EffortBackend: ModelBackend {
    func stream(_ prompt: PreparedPrompt, model: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(prompt.effort ?? "nil")
            continuation.finish()
        }
    }
}
