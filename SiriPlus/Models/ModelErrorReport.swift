import Foundation

/// What went wrong when a model was asked: shown where the answer would have been, with the error code
/// and the service's response, instead of a banner over the window.
struct ModelErrorReport: Equatable, Sendable {
    /// What the failure means, in the user's language.
    let summary: String
    /// The HTTP status, the network error code or the CLI's exit code; nil when there is none.
    let code: String?
    /// The service's whole response or the CLI's output; nil when there is nothing more than the summary.
    let body: String?
    /// The model that failed, as Settings names it.
    var modelTitle: String?

    init(summary: String, code: String? = nil, body: String? = nil, modelTitle: String? = nil) {
        self.summary = summary
        self.code = code
        let trimmed = body?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.body = trimmed?.isEmpty == false && trimmed != summary ? trimmed : nil
        self.modelTitle = modelTitle
    }

    init(_ error: Error, modelTitle: String? = nil) {
        let summary = error.localizedDescription
        switch error {
        case ClaudeError.http(let status, let message, let body):
            self.init(summary: summary, code: "HTTP \(status)", body: body.isEmpty ? message : body, modelTitle: modelTitle)
        case ClaudeError.api(let type, let message):
            self.init(summary: summary, code: type, body: message, modelTitle: modelTitle)
        case ClaudeCodeError.exited(_, let code, let output):
            self.init(summary: summary, code: code, body: output, modelTitle: modelTitle)
        case DeepSeekError.insufficientBalance:
            self.init(summary: summary, code: "HTTP 402", modelTitle: modelTitle)
        case let error as URLError:
            self.init(summary: summary, code: "URLError \(error.code.rawValue)", body: error.failingURL?.absoluteString, modelTitle: modelTitle)
        default:
            // Siri+'s own errors (no sign-in, no key) say everything in their summary.
            self.init(summary: summary, modelTitle: modelTitle)
        }
    }

    /// No model was added, or none does this yet.
    static func noModel(for purpose: ModelPurpose) -> ModelErrorReport {
        ModelErrorReport(summary: String(localized: "No model is set for “\(purpose.title)”. Add one in Settings → Models."))
    }

    /// One line for a hint card or a summary: "Too many requests… (HTTP 429)".
    var compactText: String {
        code.map { "\(summary) (\($0))" } ?? summary
    }

    /// Everything, for copying into a bug report or a message.
    var fullText: String {
        var lines = [String(localized: "Model access error")]
        if let modelTitle { lines.append(String(localized: "Model: \(modelTitle)")) }
        if let code { lines.append(String(localized: "Code: \(code)")) }
        lines.append(summary)
        if let body { lines += ["", body] }
        return lines.joined(separator: "\n")
    }
}
