import SwiftUI

/// The DeepSeek balance and what requests from this Mac used today, this week and this month.
struct DeepSeekUsageView: View {
    @ObservedObject var usage: DeepSeekUsageModel
    @State private var confirmsReset = false

    var body: some View {
        LabeledContent {
            if usage.isRefreshing {
                ProgressView().controlSize(.small)
            } else {
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await usage.refresh() } }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .controlSize(.small)
                    .help("Refresh")
            }
        } label: {
            balance
        }
        statistics
        HStack(spacing: 14) {
            Link("Top Up", destination: URL(string: "https://platform.deepseek.com/top_up")!)
            Link("Usage on DeepSeek", destination: URL(string: "https://platform.deepseek.com/usage")!)
            Spacer()
            Button("Reset Statistics", role: .destructive) { confirmsReset = true }
                .buttonStyle(.borderless)
                .disabled(usage.periods.month.requests == 0)
                .confirmationDialog("Reset DeepSeek statistics?", isPresented: $confirmsReset) {
                    Button("Reset", role: .destructive) { usage.resetStatistics() }
                } message: {
                    Text("The counted requests and tokens are deleted from this Mac. The balance is not affected.")
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
        let periods = [usage.periods.today, usage.periods.week, usage.periods.month]
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
            row("Requests", periods) { $0.requests.formatted() }
            row("Input tokens", periods) { Self.tokens($0.inputTokens) }
                .help("Tokens sent to the model: messages, meeting transcript, materials. Repeated ones are billed at the much lower cache price.")
            row("Output tokens", periods) { Self.tokens($0.outputTokens) }
                .help("Tokens of the answers, thinking included")
            row("Cost", periods) { Self.cost($0) }
                .help("Estimated from DeepSeek’s list prices")
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
