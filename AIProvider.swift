import Foundation

public enum AIProvider: String, CaseIterable, Identifiable {
    case groq = "Groq"
    case openAI = "OpenAI"

    public var id: String { rawValue }

    public static let userDefaultsKey = "com.lingobar.macos.selectedProvider"
    public static let selectedModelKeyPrefix = "com.lingobar.macos.selectedModel."

    public var displayName: String {
        switch self {
        case .groq:
            return "Groq"
        case .openAI:
            return "OpenAI"
        }
    }

    public var keychainAccount: String {
        switch self {
        case .groq:
            return "GROQ_API_KEY"
        case .openAI:
            return "OPENAI_API_KEY"
        }
    }

    public var chatEndpoint: URL {
        switch self {
        case .groq:
            return URL(string: "https://api.groq.com/openai/v1/chat/completions")!
        case .openAI:
            return URL(string: "https://api.openai.com/v1/chat/completions")!
        }
    }

    public var validationEndpoint: URL {
        switch self {
        case .groq:
            return URL(string: "https://api.groq.com/openai/v1/models")!
        case .openAI:
            return URL(string: "https://api.openai.com/v1/models")!
        }
    }

    public var defaultModel: String {
        switch self {
        case .groq:
            return "llama-3.3-70b-versatile"
        case .openAI:
            return "gpt-4o-mini"
        }
    }

    public var models: [String] {
        switch self {
        case .groq:
            return ["llama-3.3-70b-versatile", "openai/gpt-oss-120b"]
        case .openAI:
            return ["gpt-4o-mini", "gpt-4o"]
        }
    }

    public var consoleUrl: URL {
        switch self {
        case .groq:
            return URL(string: "https://console.groq.com/keys")!
        case .openAI:
            return URL(string: "https://platform.openai.com/api-keys")!
        }
    }

    public var keyPlaceholder: String {
        switch self {
        case .groq:
            return "gsk_..."
        case .openAI:
            return "sk-..."
        }
    }

    public var keyPromptTitle: String {
        switch self {
        case .groq:
            return "Groq API Key:"
        case .openAI:
            return "OpenAI API Key:"
        }
    }

    public var selectedModel: String {
        get {
            let key = Self.selectedModelKeyPrefix + rawValue
            if let saved = UserDefaults.standard.string(forKey: key), models.contains(saved) {
                return saved
            }
            return defaultModel
        }
        set {
            let key = Self.selectedModelKeyPrefix + rawValue
            UserDefaults.standard.set(newValue, forKey: key)
        }
    }

    public static var current: AIProvider {
        get {
            if let saved = UserDefaults.standard.string(forKey: userDefaultsKey),
               let provider = AIProvider(rawValue: saved) {
                return provider
            }
            return .groq
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: userDefaultsKey)
        }
    }
}
