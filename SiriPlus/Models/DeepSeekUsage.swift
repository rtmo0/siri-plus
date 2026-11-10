import Foundation

/// Tokens one DeepSeek request used, from the `usage` of its last stream chunk.
struct TokenUsage: Equatable, Sendable {
    var cacheHitTokens = 0
    var cacheMissTokens = 0
    var outputTokens = 0
    /// Part of `outputTokens` spent on thinking.
    var reasoningTokens = 0

    var inputTokens: Int { cacheHitTokens + cacheMissTokens }
    var totalTokens: Int { inputTokens + outputTokens }

    init(cacheHitTokens: Int = 0, cacheMissTokens: Int = 0, outputTokens: Int = 0, reasoningTokens: Int = 0) {
        self.cacheHitTokens = cacheHitTokens
        self.cacheMissTokens = cacheMissTokens
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
    }

    /// Reads a Chat Completions `usage` object; nil when it is missing or empty.
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

/// What DeepSeek requests used on one day, in the Mac's time zone.
struct DailyUsage: Codable, Equatable, Sendable {
    /// "2026-11-10".
    let day: String
    var requests = 0
    var cacheHitTokens = 0
    var cacheMissTokens = 0
    var outputTokens = 0
    var reasoningTokens = 0
    /// Estimated dollars, for requests to models with a known price.
    var cost = 0.0

    var inputTokens: Int { cacheHitTokens + cacheMissTokens }
    var totalTokens: Int { inputTokens + outputTokens }

    mutating func add(_ usage: TokenUsage, cost: Double?) {
        requests += 1
        cacheHitTokens += usage.cacheHitTokens
        cacheMissTokens += usage.cacheMissTokens
        outputTokens += usage.outputTokens
        reasoningTokens += usage.reasoningTokens
        self.cost += cost ?? 0
    }

    static func + (lhs: DailyUsage, rhs: DailyUsage) -> DailyUsage {
        var sum = lhs
        sum.requests += rhs.requests
        sum.cacheHitTokens += rhs.cacheHitTokens
        sum.cacheMissTokens += rhs.cacheMissTokens
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
