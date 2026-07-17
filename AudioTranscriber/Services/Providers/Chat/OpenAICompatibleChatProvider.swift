import Foundation

/// One streaming chat client for every OpenAI-compatible API: OpenAI itself,
/// MiniMax (international endpoint), and any custom base URL the user enters.
final class OpenAICompatibleChatProvider: ChatProvider {
    let id: ChatProviderID
    let displayName: String
    let contextCharacterBudget = 100_000

    private let baseURLProvider: () -> URL?
    private let modelProvider: () -> String
    private let secretKey: SecretKey
    private let secrets: SecretsStore
    private let session: URLSession

    init(id: ChatProviderID,
         displayName: String,
         baseURL: @escaping () -> URL?,
         model: @escaping () -> String,
         secretKey: SecretKey,
         secrets: SecretsStore = KeychainStore.shared,
         session: URLSession? = nil) {
        self.id = id
        self.displayName = displayName
        self.baseURLProvider = baseURL
        self.modelProvider = model
        self.secretKey = secretKey
        self.secrets = secrets
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 30     // inter-byte
            config.timeoutIntervalForResource = 600
            self.session = URLSession(configuration: config)
        }
    }

    var isConfigured: Bool {
        secrets.has(secretKey) && baseURLProvider() != nil
    }

    var modelIdentity: String { modelProvider() }

    // MARK: - Streaming

    private struct StreamChunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable {
                let content: String?
                let reasoning_content: String?
                let role: String?
            }
            let delta: Delta?
            let finish_reason: String?
        }
        struct BaseResp: Decodable {
            let status_code: Int?
            let status_msg: String?
        }
        let choices: [Choice]?
        let base_resp: BaseResp?
    }

    private struct APIErrorBody: Decodable {
        struct APIError: Decodable {
            let message: String?
            let type: String?
        }
        let error: APIError?
    }

    func streamChat(messages: [[String: String]], system: String?)
        -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.run(messages: messages, system: system, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(messages: [[String: String]], system: String?,
                     continuation: AsyncThrowingStream<ChatStreamEvent, Error>.Continuation) async throws {
        guard let key = secrets.get(secretKey), !key.isEmpty else {
            throw ChatProviderError.missingAPIKey(displayName)
        }
        guard let baseURL = baseURLProvider() else {
            throw ChatProviderError.missingConfiguration("\(displayName) endpoint URL not set.")
        }

        var allMessages = messages
        if let system {
            allMessages.insert(["role": "system", "content": system], at: 0)
        }

        var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": modelProvider(),
            "messages": allMessages,
            "stream": true,
            "temperature": 0.7,
        ] as [String: Any])

        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw ChatProviderError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ChatProviderError.network("Invalid response")
        }
        guard http.statusCode == 200 else {
            var body = Data()
            for try await byte in bytes {
                body.append(byte)
                if body.count > 16_384 { break }
            }
            throw Self.mapHTTPError(status: http.statusCode, body: body)
        }

        var parser = SSEParser()
        var buffer = Data()
        for try await byte in bytes {
            buffer.append(byte)
            // Parse in small batches to avoid per-byte overhead.
            if buffer.count >= 512 || byte == UInt8(ascii: "\n") {
                try Self.handleEvents(parser.consume(buffer), continuation: continuation)
                buffer.removeAll(keepingCapacity: true)
            }
            try Task.checkCancellation()
        }
        if !buffer.isEmpty {
            try Self.handleEvents(parser.consume(buffer), continuation: continuation)
        }
        try Self.handleEvents(parser.finish(), continuation: continuation)
    }

    private static func handleEvents(_ events: [String],
                                     continuation: AsyncThrowingStream<ChatStreamEvent, Error>.Continuation) throws {
        for payload in events {
            if payload == "[DONE]" { return }
            guard let data = payload.data(using: .utf8),
                  let chunk = try? JSONDecoder().decode(StreamChunk.self, from: data) else {
                continue // tolerate undecodable keep-alives
            }
            // MiniMax reports errors in base_resp even with HTTP 200.
            if let base = chunk.base_resp, let code = base.status_code, code != 0 {
                throw ChatProviderError.providerError(base.status_msg ?? "Provider error \(code)")
            }
            for choice in chunk.choices ?? [] {
                if let reasoning = choice.delta?.reasoning_content, !reasoning.isEmpty {
                    continuation.yield(.reasoning(reasoning))
                }
                if let content = choice.delta?.content, !content.isEmpty {
                    continuation.yield(.token(content))
                }
            }
        }
    }

    private static func mapHTTPError(status: Int, body: Data) -> ChatProviderError {
        let message = (try? JSONDecoder().decode(APIErrorBody.self, from: body))?.error?.message
        switch status {
        case 401, 403: return .unauthorized
        case 429: return .rateLimited
        default: return .providerError(message ?? "Provider returned HTTP \(status)")
        }
    }
}
