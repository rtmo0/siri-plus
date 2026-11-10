import AppKit
import Foundation
import Testing
@testable import SiriPlusCore

struct DeepSeekTests {
    private func json(_ value: some Encodable) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }

    @Test func chatRequestCarriesEffortImagesAndUsage() throws {
        let prompt = PreparedPrompt(
            system: "Be brief.",
            turns: [.init(role: .user, text: "What is on screen?", images: [Data([1, 2])]), .init(role: .assistant, text: "A chart.")],
            effort: "high",
            maxTokens: 4_000
        )
        let body = try json(DeepSeekChatRequest(prompt: prompt, model: "deepseek-flash"))
        #expect(body["model"] as? String == "deepseek-flash")
        #expect(body["reasoning_effort"] as? String == "high")
        #expect((body["thinking"] as? [String: Any])?["type"] as? String == "enabled")
        #expect(body["max_tokens"] as? Int == 4_000 + DeepSeekChatRequest.thinkingAllowance)
        #expect((body["stream_options"] as? [String: Any])?["include_usage"] as? Bool == true)
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.map { $0["role"] as? String } == ["system", "user", "assistant"])
        #expect(messages[0]["content"] as? String == "Be brief.")
        let parts = try #require(messages[1]["content"] as? [[String: Any]])
        #expect(parts.map { $0["type"] as? String } == ["image_url", "text"])
        #expect((parts[0]["image_url"] as? [String: Any])?["url"] as? String == "data:image/jpeg;base64,AQI=")
        #expect(messages[2]["content"] as? String == "A chart.")
    }

    @Test func noThinkingSwitchesThinkingOff() throws {
        let prompt = PreparedPrompt(system: "", turns: [.init(role: .user, text: "Hi")], effort: "none", maxTokens: 4_000)
        let body = try json(DeepSeekChatRequest(prompt: prompt, model: "deepseek-flash"))
        #expect(body["reasoning_effort"] == nil)
        #expect((body["thinking"] as? [String: Any])?["type"] as? String == "disabled")
        #expect(body["max_tokens"] as? Int == 4_000)
    }

    @Test func streamDecoderReadsTextUsageAndEnd() throws {
        var decoder = DeepSeekStreamDecoder()
        #expect(try decoder.consume(line: ": keep-alive").isEmpty)
        #expect(try decoder.consume(line: #"data: {"choices":[{"delta":{"reasoning_content":"hmm"}}]}"#).isEmpty)
        #expect(try decoder.consume(line: #"data: {"choices":[{"delta":{"content":"Привет"}}],"usage":null}"#) == [.text("Привет")])
        let last = #"data: {"choices":[{"delta":{"content":"!"},"finish_reason":"stop"}],"usage":{"prompt_tokens":120,"completion_tokens":30,"total_tokens":150,"prompt_cache_hit_tokens":100,"prompt_cache_miss_tokens":20,"completion_tokens_details":{"reasoning_tokens":12}}}"#
        #expect(try decoder.consume(line: last) == [.text("!"), .usage(TokenUsage(cacheHitTokens: 100, cacheMissTokens: 20, outputTokens: 30, reasoningTokens: 12))])
        #expect(try decoder.consume(line: "data: [DONE]") == [.finished])
        #expect(throws: OpenAIError.self) {
            _ = try decoder.consume(line: #"data: {"error":{"message":"Insufficient Balance"}}"#)
        }
    }

    @Test func costFollowsPeakHours() throws {
        let usage = TokenUsage(cacheHitTokens: 1_000_000, cacheMissTokens: 1_000_000, outputTokens: 1_000_000)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        // Tuesday 10 November 2026: 07:00 UTC is peak, 12:00 is not; Sunday is never peak.
        let peak = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 7)))
        let offPeak = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 12)))
        let sunday = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 8, hour: 7)))
        #expect(DeepSeekPrice.isPeak(peak))
        #expect(!DeepSeekPrice.isPeak(offPeak))
        #expect(!DeepSeekPrice.isPeak(sunday))
        let full = try #require(DeepSeekPrice.cost(of: usage, model: "deepseek-flash", at: peak))
        #expect(abs(full - 1.506) < 0.000_1)
        let half = try #require(DeepSeekPrice.cost(of: usage, model: "deepseek-flash", at: offPeak))
        #expect(abs(half - 0.753) < 0.000_1)
        #expect(DeepSeekPrice.cost(of: usage, model: "deepseek-unknown", at: peak) == nil)
    }

    @Test func balanceIsParsedFromStrings() throws {
        let data = Data(#"{"is_available":true,"balance_infos":[{"currency":"USD","total_balance":"4.20","granted_balance":"1.00","topped_up_balance":"3.20"}]}"#.utf8)
        let balance = try DeepSeekBalance.parse(data)
        #expect(balance.isAvailable)
        #expect(balance.amounts == [.init(currency: "USD", total: Decimal(string: "4.20")!, granted: 1, toppedUp: Decimal(string: "3.20")!)])
        #expect(balance.formatted(locale: Locale(identifier: "en_US")) == "$4.20")
    }

    @Test func modelsListGetsTitlesAndEfforts() throws {
        let data = Data(#"{"object":"list","data":[{"id":"deepseek-flash","object":"model"},{"id":"deepseek-v5-pro","object":"model"}]}"#.utf8)
        let models = try DeepSeekClient.parseModels(data)
        #expect(models.map(\.title) == ["DeepSeek Flash", "DeepSeek V5 Pro"])
        #expect(models.allSatisfy { $0.efforts == ModelEffort.deepSeekLevels })
    }

    @Test func effortIsMappedToDeepSeekLevels() {
        // "medium" for detailed answers lies between "low" and "high": the lighter one is sent.
        #expect(ModelEffort.resolve(chosen: ModelEffort.automatic, preferred: "medium", isLive: false, supported: ModelEffort.deepSeekLevels) == "low")
        #expect(ModelEffort.resolve(chosen: "xhigh", preferred: "low", isLive: false, supported: ModelEffort.deepSeekLevels) == "high")
        #expect(ModelEffort.resolve(chosen: "none", preferred: "low", isLive: false, supported: ModelEffort.deepSeekLevels) == "none")
    }

    @Test func ledgerSumsDaysAndForgetsOldOnes() throws {
        let ledger = UsageLedger(url: FileManager.default.temporaryDirectory.appending(path: "deepseek-\(UUID().uuidString).json"))
        let calendar = Calendar(identifier: .gregorian)
        let now = Date()
        let usage = TokenUsage(cacheHitTokens: 10, cacheMissTokens: 90, outputTokens: 50)
        ledger.record(usage, model: "deepseek-flash", at: now, calendar: calendar)
        ledger.record(usage, model: "deepseek-flash", at: now, calendar: calendar)
        ledger.record(usage, model: "deepseek-flash", at: calendar.date(byAdding: .day, value: -3, to: now)!, calendar: calendar)
        ledger.record(usage, model: "deepseek-flash", at: calendar.date(byAdding: .day, value: -20, to: now)!, calendar: calendar)
        let periods = UsagePeriods(days: ledger.days, now: now, calendar: calendar)
        #expect(periods.today.requests == 2)
        #expect(periods.week.requests == 3)
        #expect(periods.month.requests == 4)
        #expect(periods.month.inputTokens == 400)
        #expect(periods.month.outputTokens == 200)
        #expect(periods.today.cost > 0)

        // A request 100 days later drops days older than the kept window.
        ledger.record(usage, model: "deepseek-flash", at: calendar.date(byAdding: .day, value: 100, to: now)!, calendar: calendar)
        #expect(ledger.days.count == 1)
        ledger.reset()
        #expect(ledger.days.isEmpty)
    }

    @Test func preferencesKeepTheDeepSeekChoice() throws {
        var preferences = AssistantPreferences()
        preferences.provider = .deepSeek
        preferences.deepSeekModel = "deepseek-v4-pro"
        preferences.deepSeekEffort = "max"
        let decoded = try JSONDecoder().decode(AssistantPreferences.self, from: JSONEncoder().encode(preferences))
        #expect(decoded.selection.route == .deepSeek)
        #expect(decoded.selection.model == "deepseek-v4-pro")
        #expect(decoded.selection.effort == "max")
        // Settings saved before DeepSeek existed get its defaults.
        let old = try JSONDecoder().decode(AssistantPreferences.self, from: Data(#"{"provider":"openAI"}"#.utf8))
        #expect(old.deepSeekModel == ModelOption.deepSeekDefault.id)
    }
}

@MainActor
struct PasteTests {
    private func pasteboard() -> NSPasteboard {
        let board = NSPasteboard(name: NSPasteboard.Name("dev.siriplus.tests.\(UUID().uuidString)"))
        board.clearContents()
        return board
    }

    private var picture: NSImage {
        NSImage(size: NSSize(width: 4, height: 4), flipped: false) { rect in
            NSColor.blue.setFill()
            rect.fill()
            return true
        }
    }

    @Test func plainTextPastesAsUsual() {
        let board = pasteboard()
        board.setString("hello", forType: .string)
        #expect(PastedContent.read(from: board) == nil)
    }

    @Test func copiedFilesAreAttached() throws {
        let board = pasteboard()
        let url = FileManager.default.temporaryDirectory.appending(path: "paste-\(UUID().uuidString).txt")
        try "notes".write(to: url, atomically: true, encoding: .utf8)
        board.writeObjects([url as NSURL])
        guard case .files(let urls)? = PastedContent.read(from: board) else {
            Issue.record("Expected files")
            return
        }
        #expect(urls.map(\.lastPathComponent) == [url.lastPathComponent])
    }

    @Test func aPictureWithoutTextIsAttached() {
        let board = pasteboard()
        board.writeObjects([picture])
        guard case .image? = PastedContent.read(from: board) else {
            Issue.record("Expected an image")
            return
        }
    }

    @Test func textWithAPictureOfItPastesAsText() {
        let board = pasteboard()
        board.declareTypes([.string, .tiff], owner: nil)
        board.setString("A1\tB1", forType: .string)
        board.setData(picture.tiffRepresentation, forType: .tiff)
        #expect(PastedContent.read(from: board) == nil)
        board.setString("https://example.com/cat.png", forType: .string)
        guard case .image? = PastedContent.read(from: board) else {
            Issue.record("A copied web image should be attached")
            return
        }
    }
}
