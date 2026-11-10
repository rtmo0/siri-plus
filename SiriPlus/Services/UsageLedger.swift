import Foundation
import Synchronization

/// Counts what one provider's API requests used, per day, in one JSON file in Application Support.
/// API keys are billed per token, so Settings shows these totals (and DeepSeek's balance).
final class UsageLedger: Sendable {
    /// Days older than this are dropped.
    static let keptDays = 90

    private let url: URL?
    private let state: Mutex<[DailyUsage]>
    private let observer = Mutex<(@Sendable () -> Void)?>(nil)

    /// - Parameter url: nil keeps the counts in memory only.
    init(url: URL?) {
        self.url = url
        let saved = url.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode([DailyUsage].self, from: $0) }
        state = Mutex(saved ?? [])
    }

    var days: [DailyUsage] { state.withLock { $0 } }

    /// Called after every recorded request, on any thread.
    func observe(_ handler: @escaping @Sendable () -> Void) {
        observer.withLock { $0 = handler }
    }

    /// - Parameter cost: the estimated dollars, nil when the model has no known price.
    func record(_ usage: TokenUsage, cost: Double?, at date: Date = Date(), calendar: Calendar = .current) {
        let key = DailyUsage.key(for: date, calendar: calendar)
        let days = state.withLock { days in
            if let index = days.firstIndex(where: { $0.day == key }) {
                days[index].add(usage, cost: cost)
            } else {
                var day = DailyUsage(day: key)
                day.add(usage, cost: cost)
                days.append(day)
            }
            let oldest = calendar.date(byAdding: .day, value: -Self.keptDays, to: date).map { DailyUsage.key(for: $0, calendar: calendar) } ?? ""
            // "yyyy-MM-dd" keys sort by date.
            days.removeAll { $0.day < oldest }
            return days
        }
        save(days)
        observer.withLock { $0 }?()
    }

    func reset() {
        state.withLock { $0 = [] }
        save([])
        observer.withLock { $0 }?()
    }

    private func save(_ days: [DailyUsage]) {
        guard let url, let data = try? JSONEncoder().encode(days) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

/// One ledger per provider reached with an API key or a server address.
struct UsageLedgers: Sendable {
    let claude: UsageLedger
    let openAI: UsageLedger
    let deepSeek: UsageLedger
    let custom: UsageLedger

    /// - Parameter directory: nil keeps every count in memory only.
    init(directory: URL? = URL.applicationSupportDirectory.appending(path: "SiriPlus/Usage")) {
        let file = { (name: String) in directory?.appending(path: "\(name).json") }
        claude = UsageLedger(url: file("claude-api"))
        openAI = UsageLedger(url: file("openai-api"))
        deepSeek = UsageLedger(url: file("deepseek"))
        custom = UsageLedger(url: file("other"))
    }

    subscript(provider: AIProvider) -> UsageLedger {
        switch provider {
        case .claude: claude
        case .openAI: openAI
        case .deepSeek: deepSeek
        case .custom: custom
        }
    }

    /// Records a finished request with its estimated cost.
    func record(_ usage: TokenUsage, provider: AIProvider, model: String, at date: Date = Date()) {
        self[provider].record(usage, cost: APIPricing.cost(of: usage, provider: provider, model: model, at: date), at: date)
    }
}
