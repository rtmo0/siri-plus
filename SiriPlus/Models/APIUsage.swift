import Foundation

/// Tokens one API request used, as the provider reports them at the end of the stream.
struct TokenUsage: Equatable, Sendable {
    /// Input read from the provider's prompt cache, billed at a fraction of the price.
    var cacheHitTokens = 0
    /// Input billed at the full price.
    var cacheMissTokens = 0
    /// Input written to the cache (Claude), billed a little above the full price.
    var cacheWriteTokens = 0
    var outputTokens = 0
    /// Part of `outputTokens` spent on thinking.
    var reasoningTokens = 0

    var inputTokens: Int { cacheHitTokens + cacheMissTokens + cacheWriteTokens }
    var totalTokens: Int { inputTokens + outputTokens }

    init(cacheHitTokens: Int = 0, cacheMissTokens: Int = 0, cacheWriteTokens: Int = 0, outputTokens: Int = 0, reasoningTokens: Int = 0) {
        self.cacheHitTokens = cacheHitTokens
        self.cacheMissTokens = cacheMissTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
    }

    /// Reads a Messages API `usage` object (Claude), as `message_start` carries it.
    init(claude usage: [String: Any]) {
        let int = { (key: String) in (usage[key] as? NSNumber)?.intValue ?? 0 }
        self.init(cacheHitTokens: int("cache_read_input_tokens"), cacheMissTokens: int("input_tokens"),
                  cacheWriteTokens: int("cache_creation_input_tokens"), outputTokens: int("output_tokens"))
    }

    /// Reads a Responses API `usage` object (OpenAI).
    init(responses usage: [String: Any]) {
        let int = { (value: Any?) in (value as? NSNumber)?.intValue ?? 0 }
        let input = int(usage["input_tokens"])
        let cached = int((usage["input_tokens_details"] as? [String: Any])?["cached_tokens"])
        self.init(cacheHitTokens: cached, cacheMissTokens: max(0, input - cached), outputTokens: int(usage["output_tokens"]),
                  reasoningTokens: int((usage["output_tokens_details"] as? [String: Any])?["reasoning_tokens"]))
    }

    /// Reads a Chat Completions `usage` object (DeepSeek and OpenAI-compatible servers); nil when it is missing or empty.
    init?(json: Any?) {
        guard let usage = json as? [String: Any] else { return nil }
        let int = { (key: String) in (usage[key] as? NSNumber)?.intValue }
        let prompt = int("prompt_tokens") ?? 0
        let hit = int("prompt_cache_hit_tokens") ?? ((usage["prompt_tokens_details"] as? [String: Any])?["cached_tokens"] as? NSNumber)?.intValue ?? 0
        cacheHitTokens = hit
        cacheMissTokens = int("prompt_cache_miss_tokens") ?? max(0, prompt - hit)
        outputTokens = int("completion_tokens") ?? 0
        reasoningTokens = ((usage["completion_tokens_details"] as? [String: Any])?["reasoning_tokens"] as? NSNumber)?.intValue ?? 0
        if totalTokens == 0 { return nil }
    }
}

/// Estimated cost of a request at the provider's list prices; nil where no price is known
/// (OpenAI's models, servers of the "Other" provider).
enum APIPricing {
    static func cost(of usage: TokenUsage, provider: AIProvider, model: String, at date: Date = Date()) -> Double? {
        switch provider {
        case .deepSeek: DeepSeekPrice.cost(of: usage, model: model, at: date)
        case .claude: ClaudePrice.of(model).map { $0.cost(of: usage) }
        case .openAI, .custom: nil
        }
    }
}

/// Claude API list prices in US dollars per million tokens (November 2026). A cache write costs 1.25 times the input.
struct ClaudePrice: Equatable, Sendable {
    let input: Double
    let output: Double
    let cacheRead: Double

    static func of(_ model: String) -> ClaudePrice? {
        switch model {
        case "claude-opus-5-5": ClaudePrice(input: 4, output: 20, cacheRead: 0.2)
        case "claude-opus-5", "claude-opus-4-8", "claude-opus-4-7", "claude-opus-4-6": ClaudePrice(input: 5, output: 25, cacheRead: 0.5)
        case "claude-fable-5-2": ClaudePrice(input: 8, output: 40, cacheRead: 0.2)
        case "claude-fable-5-1", "claude-fable-5": ClaudePrice(input: 10, output: 50, cacheRead: 1)
        case "claude-sonnet-5-5": ClaudePrice(input: 2, output: 10, cacheRead: 0.1)
        case "claude-sonnet-5": ClaudePrice(input: 2, output: 10, cacheRead: 0.2)
        case "claude-sonnet-4-6": ClaudePrice(input: 3, output: 15, cacheRead: 0.3)
        case "claude-haiku-5-5": ClaudePrice(input: 0.1, output: 0.5, cacheRead: 0.01)
        case "claude-haiku-4-5": ClaudePrice(input: 1, output: 5, cacheRead: 0.1)
        default: nil
        }
    }

    func cost(of usage: TokenUsage) -> Double {
        let dollars = Double(usage.cacheMissTokens) * input
            + Double(usage.cacheWriteTokens) * input * 1.25
            + Double(usage.cacheHitTokens) * cacheRead
            + Double(usage.outputTokens) * output
        return dollars / 1_000_000
    }
}

/// DeepSeek's list prices in US dollars per million tokens, used to estimate what requests cost.
/// The balance in Settings is the exact figure; this is an estimate for the periods it shows.
struct DeepSeekPrice: Equatable, Sendable {
    let cacheHit: Double
    let cacheMiss: Double
    let output: Double

    /// Peak prices as of November 2026 (api-docs.deepseek.com/quick_start/pricing); off-peak hours cost half.
    static func peak(for model: String) -> DeepSeekPrice? {
        switch model {
        case "deepseek-flash", "deepseek-v4-flash", "deepseek-v4-flash-vision-exp":
            DeepSeekPrice(cacheHit: 0.006, cacheMiss: 0.3, output: 1.2)
        case "deepseek-v4-pro":
            DeepSeekPrice(cacheHit: 0.044, cacheMiss: 1.32, output: 3.96)
        default:
            nil
        }
    }

    /// Peak hours: 01:00–04:00 and 06:00–10:00 UTC, Monday to Friday.
    static func isPeak(_ date: Date) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let weekday = calendar.component(.weekday, from: date)
        guard (2...6).contains(weekday) else { return false }
        let hour = calendar.component(.hour, from: date)
        return (1..<4).contains(hour) || (6..<10).contains(hour)
    }

    /// The estimated cost of a request in US dollars, or nil for a model without a known price.
    static func cost(of usage: TokenUsage, model: String, at date: Date) -> Double? {
        guard let price = peak(for: model) else { return nil }
        let factor = isPeak(date) ? 1.0 : 0.5
        let dollars = Double(usage.cacheHitTokens) * price.cacheHit
            + Double(usage.cacheMissTokens) * price.cacheMiss
            + Double(usage.outputTokens) * price.output
        return dollars / 1_000_000 * factor
    }
}

/// The account balance `GET /user/balance` reports.
struct DeepSeekBalance: Equatable, Sendable {
    struct Amount: Equatable, Sendable {
        let currency: String
        let total: Decimal
        let granted: Decimal
        let toppedUp: Decimal

        /// "$4.20" or "¥110.00".
        func formatted(locale: Locale = .current) -> String {
            total.formatted(.currency(code: currency).precision(.fractionLength(2)).locale(locale))
        }
    }

    /// False when the balance is too low for API calls.
    let isAvailable: Bool
    let amounts: [Amount]
    var fetchedAt = Date()

    /// Every currency on the account: "$4.20 · ¥10.00".
    var formatted: String { formatted() }

    func formatted(locale: Locale = .current) -> String {
        amounts.isEmpty ? "—" : amounts.map { $0.formatted(locale: locale) }.joined(separator: " · ")
    }

    static func parse(_ data: Data, now: Date = Date()) throws -> DeepSeekBalance {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let isAvailable = object["is_available"] as? Bool else { throw ClaudeError.invalidResponse }
        let decimal = { (value: Any?) -> Decimal in
            if let text = value as? String { return Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) ?? 0 }
            return (value as? NSNumber)?.decimalValue ?? 0
        }
        let amounts = (object["balance_infos"] as? [[String: Any]] ?? []).compactMap { info -> Amount? in
            guard let currency = info["currency"] as? String else { return nil }
            return Amount(currency: currency, total: decimal(info["total_balance"]), granted: decimal(info["granted_balance"]), toppedUp: decimal(info["topped_up_balance"]))
        }
        return DeepSeekBalance(isAvailable: isAvailable, amounts: amounts, fetchedAt: now)
    }
}

/// What one provider's requests used on one day, in the Mac's time zone.
struct DailyUsage: Codable, Equatable, Sendable {
    /// "2026-11-10".
    let day: String
    var requests = 0
    var cacheHitTokens = 0
    var cacheMissTokens = 0
    var cacheWriteTokens = 0
    var outputTokens = 0
    var reasoningTokens = 0
    /// Estimated dollars, for requests to models with a known price.
    var cost = 0.0

    var inputTokens: Int { cacheHitTokens + cacheMissTokens + cacheWriteTokens }
    var totalTokens: Int { inputTokens + outputTokens }

    init(day: String) {
        self.day = day
    }

    // Days saved before a counter existed lack its key.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        day = try container.decode(String.self, forKey: .day)
        let int = { (key: CodingKeys) in try container.decodeIfPresent(Int.self, forKey: key) ?? 0 }
        requests = try int(.requests)
        cacheHitTokens = try int(.cacheHitTokens)
        cacheMissTokens = try int(.cacheMissTokens)
        cacheWriteTokens = try int(.cacheWriteTokens)
        outputTokens = try int(.outputTokens)
        reasoningTokens = try int(.reasoningTokens)
        cost = try container.decodeIfPresent(Double.self, forKey: .cost) ?? 0
    }

    mutating func add(_ usage: TokenUsage, cost: Double?) {
        requests += 1
        cacheHitTokens += usage.cacheHitTokens
        cacheMissTokens += usage.cacheMissTokens
        cacheWriteTokens += usage.cacheWriteTokens
        outputTokens += usage.outputTokens
        reasoningTokens += usage.reasoningTokens
        self.cost += cost ?? 0
    }

    static func + (lhs: DailyUsage, rhs: DailyUsage) -> DailyUsage {
        var sum = lhs
        sum.requests += rhs.requests
        sum.cacheHitTokens += rhs.cacheHitTokens
        sum.cacheMissTokens += rhs.cacheMissTokens
        sum.cacheWriteTokens += rhs.cacheWriteTokens
        sum.outputTokens += rhs.outputTokens
        sum.reasoningTokens += rhs.reasoningTokens
        sum.cost += rhs.cost
        return sum
    }

    static func key(for date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

/// Totals for the periods Settings shows.
struct UsagePeriods: Equatable, Sendable {
    var today = DailyUsage(day: "today")
    var week = DailyUsage(day: "week")
    var month = DailyUsage(day: "month")

    /// Sums the days of the last 1, 7 and 30 days, today included.
    init(days: [DailyUsage] = [], now: Date = Date(), calendar: Calendar = .current) {
        func since(_ count: Int) -> Set<String> {
            Set((0..<count).compactMap { calendar.date(byAdding: .day, value: -$0, to: now).map { DailyUsage.key(for: $0, calendar: calendar) } })
        }
        let (day, seven, thirty) = (since(1), since(7), since(30))
        for usage in days {
            if day.contains(usage.day) { today = today + usage }
            if seven.contains(usage.day) { week = week + usage }
            if thirty.contains(usage.day) { month = month + usage }
        }
    }
}
