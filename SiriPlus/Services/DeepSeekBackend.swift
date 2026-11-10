import Foundation

enum DeepSeekError: LocalizedError, Equatable {
    case missingAPIKey
    case insufficientBalance

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: String(localized: "Add a DeepSeek API key in Settings.")
        case .insufficientBalance: String(localized: "The DeepSeek balance has run out. Top it up on platform.deepseek.com.")
        }
    }
}

/// Request body for DeepSeek's OpenAI-compatible `POST /chat/completions`.
struct DeepSeekChatRequest: Encodable, Sendable {
    struct Part: Encodable, Equatable, Sendable {
        struct ImageURL: Encodable, Equatable, Sendable {
            let url: String
        }

        let type: String
        var text: String?
        var imageURL: ImageURL?

        enum CodingKeys: String, CodingKey {
            case type, text
            case imageURL = "image_url"
        }
    }

    /// A message's content: plain text, or parts when it carries images.
    enum Content: Encodable, Equatable, Sendable {
        case text(String)
        case parts([Part])

        func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .text(let text): try container.encode(text)
            case .parts(let parts): try container.encode(parts)
            }
        }
    }

    struct Message: Encodable, Sendable {
        let role: String
        let content: Content
    }

    struct Thinking: Encodable, Sendable {
        let type: String
    }

    struct StreamOptions: Encodable, Sendable {
        var includeUsage = true

        enum CodingKeys: String, CodingKey {
            case includeUsage = "include_usage"
        }
    }

    let model: String
    let messages: [Message]
    let maxTokens: Int
    /// "none", "low", "high" or "max"; nil leaves DeepSeek's default.
    let reasoningEffort: String?
    let thinking: Thinking?
    var stream = true
    var streamOptions = StreamOptions()

    enum CodingKeys: String, CodingKey {
        case model, messages, stream, thinking
        case maxTokens = "max_tokens"
        case reasoningEffort = "reasoning_effort"
        case streamOptions = "stream_options"
    }

    /// Thinking counts toward `max_tokens`, so a thinking request gets room on top of the answer.
    static let thinkingAllowance = 16_000

    init(prompt: PreparedPrompt, model: String) {
        self.model = model
        let thinks = prompt.effort != "none"
        reasoningEffort = thinks ? prompt.effort : nil
        thinking = Thinking(type: thinks ? "enabled" : "disabled")
        maxTokens = prompt.maxTokens + (thinks ? Self.thinkingAllowance : 0)
        messages = [Message(role: "system", content: .text(prompt.system))] + prompt.turns.map { turn in
            guard turn.role == .user, !turn.images.isEmpty else {
                return Message(role: turn.role.rawValue, content: .text(turn.text))
            }
            let images = turn.images.map { Part(type: "image_url", imageURL: .init(url: "data:image/jpeg;base64,\($0.base64EncodedString())")) }
            return Message(role: "user", content: .parts(images + [Part(type: "text", text: turn.text)]))
        }
    }
}

/// Reads DeepSeek's Chat Completions server-sent events.
struct DeepSeekStreamDecoder {
    enum Event: Equatable {
        case text(String)
        case usage(TokenUsage)
        case finished
    }

    /// One line of the stream can carry both text and usage, so it yields a list.
    mutating func consume(line: String) throws -> [Event] {
        guard line.hasPrefix("data:") else { return [] }
        let data = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if data == "[DONE]" { return [.finished] }
        guard let object = try? JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any] else { return [] }
        if let error = object["error"] as? [String: Any] {
            throw OpenAIError.failed(error["message"] as? String ?? String(localized: "The model could not complete the request."))
        }
        var events: [Event] = []
        let choice = (object["choices"] as? [[String: Any]])?.first
        if let text = (choice?["delta"] as? [String: Any])?["content"] as? String, !text.isEmpty {
            events.append(.text(text))
        }
        if let usage = TokenUsage(json: object["usage"]) {
            events.append(.usage(usage))
        }
        if choice?["finish_reason"] as? String == "insufficient_system_resource" {
            throw OpenAIError.failed(String(localized: "DeepSeek is overloaded right now. Try again in a minute."))
        }
        return events
    }
}

/// DeepSeek's API with a key: chat, the model list and the balance.
struct DeepSeekClient: Sendable {
    static let base = URL(string: "https://api.deepseek.com")!
    let apiKey: String
    var session: URLSession = .shared

    private func request(_ path: String) -> URLRequest {
        var request = URLRequest(url: Self.base.appending(path: path))
        request.timeoutInterval = 20
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func get(_ path: String) async throws -> Data {
        let (data, response) = try await session.data(for: request(path))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw ClaudeError.http(status: status, message: ClaudeClient.errorMessage(from: data)) }
        return data
    }

    /// Also checks the key: an unknown key fails with HTTP 401.
    func balance() async throws -> DeepSeekBalance {
        try DeepSeekBalance.parse(try await get("user/balance"))
    }

    func models() async throws -> [ModelOption] {
        try Self.parseModels(try await get("models"))
    }

    static func parseModels(_ data: Data) throws -> [ModelOption] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = object["data"] as? [[String: Any]] else { throw ClaudeError.invalidResponse }
        return list.compactMap { $0["id"] as? String }.map(ModelOption.deepSeek)
    }

    /// Streams the reply's text and reports the tokens it used once it ends.
    func streamChat(_ body: DeepSeekChatRequest, onText: @Sendable (String) -> Void, onUsage: @Sendable (TokenUsage) -> Void) async throws {
        var request = request("chat/completions")
        request.httpMethod = "POST"
        // A thinking model may stay silent for a while before the first word.
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(body)

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClaudeError.invalidResponse }
        guard http.statusCode == 200 else {
            if http.statusCode == 402 { throw DeepSeekError.insufficientBalance }
            var raw = Data()
            for try await byte in bytes { raw.append(byte) }
            throw ClaudeError.http(status: http.statusCode, message: ClaudeClient.errorMessage(from: raw))
        }
        var decoder = DeepSeekStreamDecoder()
        for try await line in bytes.lines {
            try Task.checkCancellation()
            for event in try decoder.consume(line: line) {
                switch event {
                case .text(let text): onText(text)
                case .usage(let usage): onUsage(usage)
                case .finished: return
                }
            }
        }
    }
}

/// DeepSeek models with an API key from the keychain; every request's tokens go to the ledger.
struct DeepSeekBackend: ModelBackend {
    let keyStore: any SecretStoring
    let ledger: UsageLedger

    func stream(_ prompt: PreparedPrompt, model: String) -> AsyncThrowingStream<String, Error> {
        let keyStore = keyStore
        let ledger = ledger
        let model = model.isEmpty ? ModelOption.deepSeekDefault.id : model
        let body = DeepSeekChatRequest(prompt: prompt, model: model)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let key = try keyStore.read()?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
                        throw DeepSeekError.missingAPIKey
                    }
                    try await DeepSeekClient(apiKey: key).streamChat(body) { continuation.yield($0) } onUsage: {
                        ledger.record($0, model: model)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
