import SwiftUI

/// What requests with a key or a server used today, this week and this month; with DeepSeek, the balance too.
struct APIUsageView: View {
    @ObservedObject var usage: APIUsageModel
    let provider: AIProvider
    @State private var confirmsReset = false

    /// Only Claude and DeepSeek have prices Siri+ knows.
    private var showsCost: Bool { provider == .claude || provider == .deepSeek }

    var body: some View {
        if provider == .deepSeek {
            LabeledContent {
                if usage.isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { await usage.refreshBalance() } }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.glass)
                        .buttonBorderShape(.circle)
                        .controlSize(.small)
                        .help("Refresh")
                }
            } label: {
                balance
            }
        }
        statistics
        HStack(spacing: 14) {
            switch provider {
            case .deepSeek:
                Link("Top Up", destination: URL(string: "https://platform.deepseek.com/top_up")!)
                Link("Usage on DeepSeek", destination: URL(string: "https://platform.deepseek.com/usage")!)
            case .openAI:
                Link("Usage on OpenAI", destination: URL(string: "https://platform.openai.com/usage")!)
            case .claude, .custom:
                EmptyView()
            }
            Spacer()
            Button("Reset Statistics", role: .destructive) { confirmsReset = true }
                .buttonStyle(.borderless)
                .disabled(usage.periods(for: provider).month.requests == 0)
                .confirmationDialog("Reset the statistics?", isPresented: $confirmsReset) {
                    Button("Reset", role: .destructive) { usage.resetStatistics(for: provider) }
                } message: {
                    Text("The counted requests and tokens are deleted from this Mac. Nothing changes with the provider.")
                }
        }
        .font(.callout)
    }

    @ViewBuilder
    private var balance: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Balance")
            if let balance = usage.balance {
                Text(verbatim: balance.formatted)
                    .font(.title2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(balance.isAvailable ? Color.primary : Color.red)
                if !balance.isAvailable {
                    Label("Not enough for requests. Top up the balance.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                } else if let granted = balance.amounts.first(where: { $0.granted > 0 }) {
                    Text("Including \(granted.granted.formatted(.currency(code: granted.currency))) granted by DeepSeek")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("Updated \(balance.fetchedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else if usage.balanceError == nil {
                Text("Loading…").font(.caption).foregroundStyle(.secondary)
            }
            if let error = usage.balanceError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var statistics: some View {
        let periods = usage.periods(for: provider)
        let columns = [periods.today, periods.week, periods.month]
        return Grid(alignment: .trailing, horizontalSpacing: 18, verticalSpacing: 6) {
            GridRow {
                Text(verbatim: "")
                Text("Today")
                Text("7 days")
                Text("30 days")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Divider()
            row("Requests", columns) { $0.requests.formatted() }
            row("Input tokens", columns) { Self.tokens($0.inputTokens) }
                .help("Tokens sent to the model: messages, meeting transcript, materials. Repeated ones are billed at the much lower cache price.")
            row("Output tokens", columns) { Self.tokens($0.outputTokens) }
                .help("Tokens of the answers, thinking included")
            if showsCost {
                row("Cost", columns) { Self.cost($0) }
                    .help("Estimated from the provider’s list prices")
            }
        }
        .font(.callout.monospacedDigit())
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ title: LocalizedStringKey, _ periods: [DailyUsage], value: @escaping (DailyUsage) -> String) -> some View {
        GridRow {
            Text(title)
                .gridColumnAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(periods.indices, id: \.self) { index in
                Text(verbatim: value(periods[index]))
            }
        }
    }

    static func tokens(_ count: Int) -> String {
        count == 0 ? "—" : count.formatted(.number.notation(.compactName))
    }

    static func cost(_ usage: DailyUsage) -> String {
        guard usage.requests > 0 else { return "—" }
        let digits = usage.cost < 1 ? 3 : 2
        return "≈ " + usage.cost.formatted(.currency(code: "USD").precision(.fractionLength(digits)))
    }
}
