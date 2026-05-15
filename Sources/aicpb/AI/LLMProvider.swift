import Foundation

enum LLMProvider: String, CaseIterable {
    case openRouter = "openrouter"
    case anthropic  = "anthropic"

    var displayName: String {
        switch self {
        case .openRouter: return "OpenRouter"
        case .anthropic:  return "Anthropic"
        }
    }

    var keychainAccount: String {
        switch self {
        case .openRouter: return Keychain.openRouterAccount
        case .anthropic:  return Keychain.anthropicAccount
        }
    }

    var keyPlaceholder: String {
        switch self {
        case .openRouter: return "sk-or-..."
        case .anthropic:  return "sk-ant-..."
        }
    }

    var keysURL: URL {
        switch self {
        case .openRouter: return URL(string: "https://openrouter.ai/keys")!
        case .anthropic:  return URL(string: "https://console.anthropic.com/settings/keys")!
        }
    }
}
