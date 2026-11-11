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

enum CustomServerError: LocalizedError, Equatable {
    case notConnected
    case invalidAddress
    case noModel

    var errorDescription: String? {
        switch self {
        case .notConnected: String(localized: "Connect a server under Settings → Model → Other.")
        case .invalidAddress: String(localized: "Enter the server address, for example http://localhost:11434/v1.")
        case .noModel: String(localized: "The server lists no models. Enter a model name in Settings.")
        }
    }
}

/// Request body for an OpenAI-compatible `POST /chat/completions`.
struct ChatCompletionsRequest: Encodable, Sendable {
    /// DeepSeek takes thinking settings; other servers get only what every OpenAI-compatible API accepts.
    enum Flavor: Sendable {
        case deepSeek
        case generic
    }

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
    /// Nil leaves the server's own limit: models behind other servers differ too much to pick one.
    let maxTokens: Int?
    /// DeepSeek: "none", "low", "high" or "max".
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

    /// Thinking counts toward DeepSeek's `max_tokens`, so a thinking request gets room on top of the answer.
    static let thinkingAllowance = 16_000

    init(prompt: PreparedPrompt, model: String, flavor: Flavor = .deepSeek) {
        self.model = model
        switch flavor {
        case .deepSeek:
            let thinks = prompt.effort != "none"
            reasoningEffort = thinks ? prompt.effort : nil
            thinking = Thinking(type: thinks ? "enabled" : "disabled")
            maxTokens = prompt.maxTokens + (thinks ? Self.thinkingAllowance : 0)
        case .generic:
            reasoningEffort = nil
            thinking = nil
            maxTokens = nil
        }
        messages = [Message(role: "system", content: .text(prompt.system))] + prompt.turns.map { turn in
            guard turn.role == .user, !turn.images.isEmpty else {
                return Message(role: turn.role.rawValue, content: .text(turn.text))
            }
            let images = turn.images.map { Part(type: "image_url", imageURL: .init(url: "data:image/jpeg;base64,\($0.base64EncodedString())")) }
            return Message(role: "user", content: .parts(images + [Part(type: "text", text: turn.text)]))
        }
    }
}

/// Reads Chat Completions server-sent events.
struct ChatCompletionsStreamDecoder {
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
            throw OpenAIError.failed(String(localized: "The server is overloaded right now. Try again in a minute."))
        }
        return events
    }
}

/// An OpenAI-compatible API: DeepSeek, or a server of the "Other" provider.
struct ChatCompletionsClient: Sendable {
    static let deepSeekBase = URL(string: "https://api.deepseek.com")!

    let base: URL
    /// Local servers such as Ollama need none.
    let apiKey: String?
    var flavor: ChatCompletionsRequest.Flavor = .generic
    var session: URLSession = .shared

    static func deepSeek(apiKey: String) -> ChatCompletionsClient {
        ChatCompletionsClient(base: deepSeekBase, apiKey: apiKey, flavor: .deepSeek)
    }

    /// "http://localhost:11434" → ".../v1": servers serve the API under /v1 unless a path is given.
    static func normalizedBase(_ text: String) -> URL? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard !trimmed.isEmpty else { return nil }
        if !trimmed.contains("://") { trimmed = (trimmed.hasPrefix("localhost") || trimmed.hasPrefix("127.") ? "http://" : "https://") + trimmed }
        guard var components = URLComponents(string: trimmed), let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https", components.host?.isEmpty == false else { return nil }
        if components.path.isEmpty { components.path = "/v1" }
        return components.url
    }

    private func request(_ path: String) -> URLRequest {
        var request = URLRequest(url: base.appending(path: path))
        request.timeoutInterval = 20
        if let apiKey, !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func get(_ path: String) async throws -> Data {
        let (data, response) = try await session.data(for: request(path))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw ClaudeError.http(status: status, message: ClaudeClient.errorMessage(from: data), body: ClaudeClient.responseBody(data)) }
        return data
    }

    /// DeepSeek's balance; also checks the key, as an unknown key fails with HTTP 401.
    func balance() async throws -> DeepSeekBalance {
        try DeepSeekBalance.parse(try await get("user/balance"))
    }

    /// The models the server offers; also checks the key and the address.
    func models() async throws -> [ModelOption] {
        try Self.parseModels(try await get("models"), flavor: flavor)
    }

    static func parseModels(_ data: Data, flavor: ChatCompletionsRequest.Flavor) throws -> [ModelOption] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = object["data"] as? [[String: Any]] else { throw ClaudeError.invalidResponse }
        let ids = list.compactMap { $0["id"] as? String }
        switch flavor {
        case .deepSeek: return ids.map(ModelOption.deepSeek)
        case .generic: return ids.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { ModelOption(id: $0, title: $0, efforts: []) }
        }
    }

    /// Streams the reply's text and reports the tokens it used once it ends.
    func streamChat(_ body: ChatCompletionsRequest, onText: @Sendable (String) -> Void, onUsage: @Sendable (TokenUsage) -> Void) async throws {
        var request = request("chat/completions")
        request.httpMethod = "POST"
        // A thinking or local model may stay silent for a while before the first word.
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(body)

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClaudeError.invalidResponse }
        guard http.statusCode == 200 else {
            if http.statusCode == 402, flavor == .deepSeek { throw DeepSeekError.insufficientBalance }
            var raw = Data()
            for try await byte in bytes { raw.append(byte) }
            throw ClaudeError.http(status: http.statusCode, message: ClaudeClient.errorMessage(from: raw), body: ClaudeClient.responseBody(raw))
        }
        var decoder = ChatCompletionsStreamDecoder()
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
    let ledgers: UsageLedgers

    func stream(_ prompt: PreparedPrompt, model: String) -> AsyncThrowingStream<String, Error> {
        let keyStore = keyStore, ledgers = ledgers
        let model = model.isEmpty ? ModelOption.deepSeekDefault.id : model
        let body = ChatCompletionsRequest(prompt: prompt, model: model, flavor: .deepSeek)
        return ChatCompletionsBackend.run { continuation in
            guard let key = try keyStore.read()?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
                throw DeepSeekError.missingAPIKey
            }
            try await ChatCompletionsClient.deepSeek(apiKey: key).streamChat(body) { continuation.yield($0) } onUsage: {
                ledgers.record($0, provider: .deepSeek, model: model)
            }
        }
    }
}

/// A server of the "Other" provider at the address chosen in Settings, with an optional key.
struct ChatCompletionsBackend: ModelBackend {
    let base: URL?
    let keyStore: any SecretStoring
    let ledgers: UsageLedgers

    func stream(_ prompt: PreparedPrompt, model: String) -> AsyncThrowingStream<String, Error> {
        let base = base, keyStore = keyStore, ledgers = ledgers
        return Self.run { continuation in
            guard let base else { throw CustomServerError.notConnected }
            let key = try keyStore.read()?.trimmingCharacters(in: .whitespacesAndNewlines)
            let client = ChatCompletionsClient(base: base, apiKey: key)
            var model = model
            if model.isEmpty {
                guard let first = try await client.models().first?.id else { throw CustomServerError.noModel }
                model = first
            }
            let body = ChatCompletionsRequest(prompt: prompt, model: model, flavor: .generic)
            try await client.streamChat(body) { continuation.yield($0) } onUsage: { [model] in
                ledgers.record($0, provider: .custom, model: model)
            }
        }
    }

    /// Runs a streaming request as a stream of text that stops when the reader stops reading.
    static func run(_ work: @escaping @Sendable (AsyncThrowingStream<String, Error>.Continuation) async throws -> Void) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await work(continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
