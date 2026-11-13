import Foundation

public enum AIProvider: String, CaseIterable, Identifiable {
    case groq = "Groq"
    case openAI = "OpenAI"
    case gemini = "Gemini"

    public var id: String { rawValue }

    public static let userDefaultsKey = "com.lingobar.macos.selectedProvider"
    public static let selectedModelKeyPrefix = "com.lingobar.macos.selectedModel."

    public var displayName: String {
        switch self {
        case .groq:
            return "Groq"
        case .openAI:
            return "OpenAI"
        case .gemini:
            return "Gemini"
        }
    }

    public var keychainAccount: String {
        switch self {
        case .groq:
            return "GROQ_API_KEY"
        case .openAI:
            return "OPENAI_API_KEY"
        case .gemini:
            return "GEMINI_API_KEY"
        }
    }

    public var chatEndpoint: URL {
        switch self {
        case .groq:
            return URL(string: "https://api.groq.com/openai/v1/chat/completions")!
        case .openAI:
            return URL(string: "https://api.openai.com/v1/chat/completions")!
        case .gemini:
            return URL(string: "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")!
        }
    }

    public var validationEndpoint: URL {
        switch self {
        case .groq:
            return URL(string: "https://api.groq.com/openai/v1/models")!
        case .openAI:
            return URL(string: "https://api.openai.com/v1/models")!
        case .gemini:
            return URL(string: "https://generativelanguage.googleapis.com/v1beta/openai/models")!
        }
    }

    public var defaultModel: String {
        switch self {
        case .groq:
            return "llama-3.3-70b-versatile"
        case .openAI:
            return "gpt-4o-mini"
        case .gemini:
            return "gemini-3.8-flash"
        }
    }

    public var models: [String] {
        switch self {
        case .groq:
            return ["llama-3.3-70b-versatile", "openai/gpt-oss-120b"]
        case .openAI:
            return ["gpt-4o-mini", "gpt-4o"]
        case .gemini:
            return ["gemini-3.8-flash", "gemini-3.5-flash-lite", "gemini-4-argon"]
        }
    }

    public var consoleUrl: URL {
        switch self {
        case .groq:
            return URL(string: "https://console.groq.com/keys")!
        case .openAI:
            return URL(string: "https://platform.openai.com/api-keys")!
        case .gemini:
            return URL(string: "https://aistudio.google.com/app/apikey")!
        }
    }

    public var keyPlaceholder: String {
        switch self {
        case .groq:
            return "gsk_..."
        case .openAI:
            return "sk-..."
        case .gemini:
            return "AIzaSy..."
        }
    }

    public var keyPromptTitle: String {
        switch self {
        case .groq:
            return "Groq API Key:"
        case .openAI:
            return "OpenAI API Key:"
        case .gemini:
            return "Gemini API Key:"
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
