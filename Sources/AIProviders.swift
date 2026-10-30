import Foundation

enum ProviderKind: String, CaseIterable {
    case anthropic, openAI, gemini, deepSeek, moonshot, custom

    var displayName: String {
        switch self {
        case .anthropic: return "Claude"
        case .openAI: return "OpenAI"
        case .gemini: return "Gemini"
        case .deepSeek: return "DeepSeek"
        case .moonshot: return "Kimi"
        case .custom: return "Custom"
        }
    }

    var defaultModel: String {
        switch self {
        case .anthropic: return "claude-opus-5-5"
        case .openAI: return "gpt-6.1-sol"
        case .gemini: return "gemini-4-argon"
        case .deepSeek: return "deepseek-flash"
        case .moonshot: return "kimi-k3.1-pro"
        case .custom: return ""
        }
    }

    /// Editable in Settings for the OpenAI-compatible providers (e.g. a regional endpoint or a local server).
    var defaultBaseURL: String {
        switch self {
        case .anthropic: return "https://api.anthropic.com"
        case .openAI: return "https://api.openai.com/v1"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta"
        case .deepSeek: return "https://api.deepseek.com"
        case .moonshot: return "https://api.moonshot.ai/v1"
        case .custom: return "http://localhost:11434/v1"
        }
    }

    var hasEditableBaseURL: Bool { [.deepSeek, .moonshot, .custom].contains(self) }
    /// Local servers (Ollama, LM Studio) usually need no key.
    var requiresKey: Bool { self != .custom }
}

struct ModelChoice {
    var provider: ProviderKind
    var model: String
}

/// AI options, stored in UserDefaults (API keys live in the keychain).
enum AISettings {
    static let didChange = Notification.Name("EasyImgAISettingsDidChange")

    private static var defaults: UserDefaults { .standard }

    static var assistantProvider: ProviderKind {
        get { defaults.string(forKey: "AssistantProvider").flatMap(ProviderKind.init) ?? .anthropic }
        set { defaults.set(newValue.rawValue, forKey: "AssistantProvider"); notify() }
    }

    static var assistant: ModelChoice { ModelChoice(provider: assistantProvider, model: model(for: assistantProvider)) }

    static func model(for provider: ProviderKind) -> String {
        defaults.string(forKey: "Model.\(provider.rawValue)") ?? provider.defaultModel
    }

    static func setModel(_ model: String, for provider: ProviderKind) {
        defaults.set(model.trimmingCharacters(in: .whitespaces), forKey: "Model.\(provider.rawValue)")
        notify()
    }

    static func baseURL(for provider: ProviderKind) -> String {
        guard provider.hasEditableBaseURL, let custom = defaults.string(forKey: "BaseURL.\(provider.rawValue)"), !custom.isEmpty else {
            return provider.defaultBaseURL
        }
        return custom
    }

    static func setBaseURL(_ url: String, for provider: ProviderKind) {
        defaults.set(url.trimmingCharacters(in: .whitespaces), forKey: "BaseURL.\(provider.rawValue)")
        notify()
    }

    static func apiKey(for provider: ProviderKind) -> String? {
        Keychain.apiKey(for: provider.rawValue)
    }

    static func setAPIKey(_ key: String, for provider: ProviderKind) {
        Keychain.setAPIKey(key, for: provider.rawValue)
        defaults.set(!key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, forKey: "HasKey.\(provider.rawValue)")
        notify()
    }

    /// Whether a key is saved, without reading the keychain (which can show a permission prompt).
    static func hasAPIKey(_ provider: ProviderKind) -> Bool {
        if let flag = defaults.object(forKey: "HasKey.\(provider.rawValue)") as? Bool { return flag }
        // Keys saved before this flag existed: check once and remember.
        let has = apiKey(for: provider) != nil
        defaults.set(has, forKey: "HasKey.\(provider.rawValue)")
        return has
    }

    /// The custom server's model can take images (its API can't tell us).
    static var customSendsImages: Bool {
        get { defaults.bool(forKey: "CustomSendsImages") }
        set { defaults.set(newValue, forKey: "CustomSendsImages"); notify() }
    }

    static var showQuickPicker: Bool {
        get { defaults.bool(forKey: "ShowModelPicker") }
        set { defaults.set(newValue, forKey: "ShowModelPicker"); notify() }
    }

    static func isConfigured(_ provider: ProviderKind) -> Bool {
        provider == .custom
            ? !(defaults.string(forKey: "BaseURL.custom") ?? "").isEmpty && !model(for: .custom).isEmpty
            : hasAPIKey(provider)
    }

    // MARK: Capabilities

    /// Image support learned from providers' model lists (DeepSeek and Kimi report it).
    private static var knownVision: [String: Bool] {
        get { defaults.dictionary(forKey: "ModelVision") as? [String: Bool] ?? [:] }
        set { defaults.set(newValue, forKey: "ModelVision") }
    }

    static func remember(_ models: [ModelInfo], for provider: ProviderKind) {
        var known = knownVision
        for model in models { if let vision = model.acceptsImages { known["\(provider.rawValue)/\(model.id)"] = vision } }
        knownVision = known
    }

    /// Whether the chosen model gets the image itself; otherwise it gets an on-device description.
    static func sendsImages(_ choice: ModelChoice) -> Bool {
        if let known = knownVision["\(choice.provider.rawValue)/\(choice.model)"] { return known }
        switch choice.provider {
        case .anthropic, .openAI, .gemini: return true
        case .deepSeek: return choice.model.contains("flash") // deepseek-v4-pro is text-only
        case .moonshot: return ["kimi-k3", "kimi-k2.6", "kimi-k2.7"].contains { choice.model.hasPrefix($0) } || choice.model.contains("vision")
        case .custom: return customSendsImages
        }
    }

    static func client(for provider: ProviderKind) -> ChatClient? {
        let key = apiKey(for: provider)
        if provider.requiresKey && key == nil { return nil }
        let base = baseURL(for: provider)
        switch provider {
        case .anthropic: return AnthropicClient(apiKey: key!, baseURL: base)
        case .gemini: return GeminiClient(apiKey: key!, baseURL: base)
        case .moonshot: return OpenAICompatibleClient(baseURL: base, apiKey: key, replaysReasoning: true)
        case .openAI, .deepSeek, .custom: return OpenAICompatibleClient(baseURL: base, apiKey: key, replaysReasoning: false)
        }
    }

    private static func notify() {
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}

struct ModelInfo {
    var id: String
    /// nil when the provider's model list doesn't say.
    var acceptsImages: Bool?
}

/// Prices as published on 2026-10-30 (USD per 1M tokens). Editable on the Costs page.
enum DefaultPrices {
    static let all: [ModelPrice] = [
        // Claude
        ModelPrice(model: "claude-fable-5-1", input: 10, output: 50, cachedInput: 0.25),
        ModelPrice(model: "claude-opus-5-5", input: 4, output: 20, cachedInput: 0.20),
        ModelPrice(model: "claude-opus-5", input: 5, output: 25, cachedInput: 0.50),
        ModelPrice(model: "claude-opus-4-8", input: 5, output: 25, cachedInput: 0.50),
        ModelPrice(model: "claude-sonnet-5-5", input: 2, output: 10, cachedInput: 0.20),
        ModelPrice(model: "claude-sonnet-5", input: 2, output: 10, cachedInput: 0.20),
        ModelPrice(model: "claude-haiku-5-5", input: 0.10, output: 0.50, cachedInput: 0.01),
        // OpenAI
        ModelPrice(model: "gpt-6-astra", input: 10, output: 50, cachedInput: 1),
        ModelPrice(model: "gpt-6.1-sol", input: 2, output: 10, cachedInput: 0.10),
        ModelPrice(model: "gpt-6.1-terra", input: 1, output: 5, cachedInput: 0.05),
        ModelPrice(model: "gpt-6-luna", input: 0.10, output: 0.50, cachedInput: 0.01),
        // Gemini (gemini-4-argon rises to $4 / $20 on 2026-12-01)
        ModelPrice(model: "gemini-4-argon", input: 2, output: 10, cachedInput: 0.10),
        ModelPrice(model: "gemini-3.8-flash", input: 0.75, output: 3.75, cachedInput: 0.075),
        ModelPrice(model: "gemini-3.5-flash-lite", input: 0.30, output: 2.50, cachedInput: 0.03),
        // DeepSeek (peak-hour prices; off-peak is half)
        ModelPrice(model: "deepseek-flash", input: 0.30, output: 1.20, cachedInput: 0.006),
        ModelPrice(model: "deepseek-v4-flash", input: 0.30, output: 1.20, cachedInput: 0.006),
        ModelPrice(model: "deepseek-v4-pro", input: 1.32, output: 3.96, cachedInput: 0.044),
        // Kimi (from third-party listings; check platform.kimi.ai)
        ModelPrice(model: "kimi-k3.1-pro", input: 2, output: 10, cachedInput: 0.20),
        ModelPrice(model: "kimi-k3", input: 3, output: 15, cachedInput: 0.30),
    ]
}
