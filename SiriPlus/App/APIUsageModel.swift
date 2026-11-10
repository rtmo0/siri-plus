import Combine
import Foundation

/// What requests with an API key or a server address used, per provider, and the DeepSeek balance.
/// Keys have no subscription limits: they are billed per token.
@MainActor
final class APIUsageModel: ObservableObject {
    @Published private(set) var periods: [AIProvider: UsagePeriods] = [:]
    @Published private(set) var balance: DeepSeekBalance?
    @Published private(set) var balanceError: String?
    @Published private(set) var isRefreshing = false

    let ledgers: UsageLedgers
    private let fetchBalance: @Sendable () async throws -> DeepSeekBalance
    private var lastRefresh = Date.distantPast

    init(ledgers: UsageLedgers, fetchBalance: @escaping @Sendable () async throws -> DeepSeekBalance) {
        self.ledgers = ledgers
        self.fetchBalance = fetchBalance
        for provider in AIProvider.allCases {
            periods[provider] = UsagePeriods(days: ledgers[provider].days)
            ledgers[provider].observe { [weak self] in
                Task { @MainActor in self?.requestRecorded(provider) }
            }
        }
    }

    func periods(for provider: AIProvider) -> UsagePeriods {
        periods[provider] ?? UsagePeriods()
    }

    /// Fetches the DeepSeek balance of the saved key; returns the error, if any.
    @discardableResult
    func refreshBalance() async -> Error? {
        guard !isRefreshing else { return nil }
        isRefreshing = true
        defer {
            isRefreshing = false
            lastRefresh = Date()
        }
        do {
            show(try await fetchBalance())
            return nil
        } catch {
            // Keeps the last known balance and says why it could not be refreshed.
            balanceError = error.localizedDescription
            return error
        }
    }

    func show(_ balance: DeepSeekBalance) {
        self.balance = balance
        balanceError = nil
    }

    /// Forgets the balance of a deleted key; the counted usage stays.
    func clearBalance() {
        balance = nil
        balanceError = nil
    }

    func resetStatistics(for provider: AIProvider) {
        ledgers[provider].reset()
        periods[provider] = UsagePeriods(days: ledgers[provider].days)
    }

    private func requestRecorded(_ provider: AIProvider) {
        periods[provider] = UsagePeriods(days: ledgers[provider].days)
        // The balance moves after each request; asks for it at most once a minute.
        if provider == .deepSeek, balance != nil, Date().timeIntervalSince(lastRefresh) > 60 {
            Task { await refreshBalance() }
        }
    }
}
