import Foundation
import Observation

/// Registry + selection for chat providers. Replaces the old LLMService in the
/// environment. Default provider: the user's explicit choice; otherwise
/// MiniMax if keyed, then OpenAI if keyed, then local MLX.
@Observable @MainActor
final class ChatService {
    let localMLX: LocalMLXChatProvider
    let miniMax: OpenAICompatibleChatProvider
    let openAI: OpenAICompatibleChatProvider
    let custom: OpenAICompatibleChatProvider

    var isLocalMLXAvailable = false
    var isCheckingLocal = false

    private let defaults: UserDefaults
    private let secrets: SecretsStore

    init(secrets: SecretsStore = KeychainStore.shared, defaults: UserDefaults = .standard) {
        self.secrets = secrets
        self.defaults = defaults

        localMLX = LocalMLXChatProvider()
        miniMax = OpenAICompatibleChatProvider(
            id: .miniMax, displayName: "MiniMax",
            baseURL: { URL(string: "https://api.minimax.io/v1") },
            model: { defaults.string(forKey: "miniMaxModel") ?? "MiniMax-M3" },
            secretKey: .miniMax, secrets: secrets)
        openAI = OpenAICompatibleChatProvider(
            id: .openAI, displayName: "OpenAI",
            baseURL: { URL(string: "https://api.openai.com/v1") },
            model: { defaults.string(forKey: "openAIChatModel") ?? "gpt-4o-mini" },
            secretKey: .openAI, secrets: secrets)
        custom = OpenAICompatibleChatProvider(
            id: .custom, displayName: "Custom Endpoint",
            baseURL: {
                guard let raw = defaults.string(forKey: "customChatBaseURL"),
                      !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
                return URL(string: raw.trimmingCharacters(in: .whitespaces))
            },
            model: { defaults.string(forKey: "customChatModel") ?? "" },
            secretKey: .custom, secrets: secrets)
    }

    func provider(for id: ChatProviderID) -> any ChatProvider {
        switch id {
        case .localMLX: return localMLX
        case .miniMax: return miniMax
        case .openAI: return openAI
        case .custom: return custom
        }
    }

    /// User's explicit selection; nil when never chosen.
    var selectedProviderID: ChatProviderID? {
        get {
            guard let raw = defaults.string(forKey: "chatProviderID") else { return nil }
            return ChatProviderID(rawValue: raw)
        }
        set {
            defaults.set(newValue?.rawValue, forKey: "chatProviderID")
        }
    }

    /// The provider all chat/summarization features should use right now.
    var activeProvider: any ChatProvider {
        if let selected = selectedProviderID {
            return provider(for: selected)
        }
        // Auto-default: MiniMax → OpenAI → local
        if miniMax.isConfigured { return miniMax }
        if openAI.isConfigured { return openAI }
        return localMLX
    }

    /// True when the active provider can actually serve requests.
    var isActiveProviderReady: Bool {
        let active = activeProvider
        if active.id == .localMLX { return isLocalMLXAvailable }
        return active.isConfigured
    }

    func checkLocalAvailability() async {
        isCheckingLocal = true
        defer { isCheckingLocal = false }
        isLocalMLXAvailable = await localMLX.checkAvailability()
    }
}
