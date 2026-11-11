import AppKit
import SwiftUI

/// A failed answer, where the answer would have been: what went wrong, the model, the error code and
/// the service's response, with a retry and a way to copy it all.
struct ModelErrorCard: View {
    let report: ModelErrorReport
    /// The panel has less room, so the response gets a lower box.
    var compact = false
    var retry: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Model access error", systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.orange)
            let details = [report.modelTitle, report.code.map { String(localized: "Code: \($0)") }].compactMap { $0 }
            if !details.isEmpty {
                Text(verbatim: details.joined(separator: " · "))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Text(verbatim: report.summary)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let body = report.body {
                ScrollView {
                    Text(verbatim: body)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: compact ? 110 : 220)
                .padding(8)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityLabel("Response")
            }
            HStack(spacing: 8) {
                if let retry {
                    Button("Try Again", systemImage: "arrow.clockwise", action: retry)
                        .buttonStyle(.glass)
                }
                Button("Copy", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report.fullText, forType: .string)
                }
                .buttonStyle(.glass)
                .help("Copy the error with its code and response")
            }
            .controlSize(.small)
            .padding(.top, 2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.orange.opacity(0.35)))
    }
}
