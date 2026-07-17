import Foundation

enum ChatProviderID: String, Codable, CaseIterable, Identifiable {
    case localMLX
    case miniMax
    case openAI
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .localMLX: return "Local (MLX)"
        case .miniMax: return "MiniMax"
        case .openAI: return "OpenAI"
        case .custom: return "Custom Endpoint"
        }
    }
}

enum ChatStreamEvent: Sendable, Equatable {
    case token(String)
    case reasoning(String)
}

enum ChatProviderError: LocalizedError {
    case missingAPIKey(String)
    case missingConfiguration(String)
    case unauthorized
    case rateLimited
    case providerError(String)
    case network(String)
    case notAvailable(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let provider):
            return "\(provider) API key not set. Add it in Settings → AI Chat."
        case .missingConfiguration(let msg):
            return msg
        case .unauthorized:
            return "Authentication failed — check your API key in Settings."
        case .rateLimited:
            return "Rate limited by the provider. Try again in a moment."
        case .providerError(let msg):
            return msg
        case .network(let msg):
            return "Network error: \(msg)"
        case .notAvailable(let msg):
            return msg
        }
    }
}

protocol ChatProvider: AnyObject {
    var id: ChatProviderID { get }
    var displayName: String { get }
    /// How much context (characters) consumers may stuff into prompts.
    var contextCharacterBudget: Int { get }
    var isConfigured: Bool { get }

    func streamChat(messages: [[String: String]], system: String?)
        -> AsyncThrowingStream<ChatStreamEvent, Error>
}

extension ChatProvider {
    /// Non-streaming convenience: accumulate tokens (reasoning is dropped).
    func generate(messages: [[String: String]], system: String? = nil) async throws -> String {
        var result = ""
        for try await event in streamChat(messages: messages, system: system) {
            if case .token(let text) = event { result += text }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func generate(prompt: String, system: String? = nil) async throws -> String {
        try await generate(messages: [["role": "user", "content": prompt]], system: system)
    }
}
