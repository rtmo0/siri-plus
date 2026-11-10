import Combine
import Foundation

/// The DeepSeek balance and what requests from this Mac used: an API key has no subscription limits,
/// it is billed per token.
@MainActor
final class DeepSeekUsageModel: ObservableObject {
    @Published private(set) var balance: DeepSeekBalance?
    @Published private(set) var balanceError: String?
    @Published private(set) var periods = UsagePeriods()
    @Published private(set) var isRefreshing = false

    let ledger: UsageLedger
    private let fetchBalance: @Sendable () async throws -> DeepSeekBalance
    private var lastRefresh = Date.distantPast

    init(ledger: UsageLedger, fetchBalance: @escaping @Sendable () async throws -> DeepSeekBalance) {
        self.ledger = ledger
        self.fetchBalance = fetchBalance
        periods = UsagePeriods(days: ledger.days)
        ledger.observe { [weak self] in
            Task { @MainActor in self?.requestRecorded() }
        }
    }

    /// Fetches the balance of the saved key; returns the error, if any.
    @discardableResult
    func refresh() async -> Error? {
        guard !isRefreshing else { return nil }
        isRefreshing = true
        defer {
            isRefreshing = false
            lastRefresh = Date()
        }
        periods = UsagePeriods(days: ledger.days)
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

    func resetStatistics() {
        ledger.reset()
        periods = UsagePeriods(days: ledger.days)
    }

    private func requestRecorded() {
        periods = UsagePeriods(days: ledger.days)
        // The balance moves after each request; asks for it at most once a minute.
        if balance != nil, Date().timeIntervalSince(lastRefresh) > 60 {
            Task { await refresh() }
        }
    }
}
