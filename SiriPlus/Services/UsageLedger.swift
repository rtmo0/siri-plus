import Foundation
import Synchronization

/// Counts what DeepSeek requests used, per day, in one JSON file in Application Support.
/// API keys are billed per token, so Settings shows these totals next to the account balance.
final class UsageLedger: Sendable {
    /// Days older than this are dropped.
    static let keptDays = 90

    private let url: URL?
    private let state: Mutex<[DailyUsage]>
    private let observer = Mutex<(@Sendable () -> Void)?>(nil)

    /// - Parameter url: nil keeps the counts in memory only.
    init(url: URL? = URL.applicationSupportDirectory.appending(path: "SiriPlus/deepseek-usage.json")) {
        self.url = url
        let saved = url.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode([DailyUsage].self, from: $0) }
        state = Mutex(saved ?? [])
    }

    var days: [DailyUsage] { state.withLock { $0 } }

    /// Called after every recorded request, on any thread.
    func observe(_ handler: @escaping @Sendable () -> Void) {
        observer.withLock { $0 = handler }
    }

    func record(_ usage: TokenUsage, model: String, at date: Date = Date(), calendar: Calendar = .current) {
        let key = DailyUsage.key(for: date, calendar: calendar)
        let cost = DeepSeekPrice.cost(of: usage, model: model, at: date)
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
