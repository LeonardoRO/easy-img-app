import Foundation

// MARK: Shared types

struct ChatTurn {
    enum Role { case user, assistant }
    var role: Role
    var text: String
    /// Sent with the first user turn when the model can see images.
    var image: ChatImage?
    /// Claude's raw content blocks (including thinking), replayed unchanged on later Claude requests.
    var anthropicBlocks: [[String: Any]]?
    /// Reasoning text from OpenAI-compatible thinking models that require it back (Kimi).
    var reasoning: String?
}

struct ChatRequest {
    var model: String
    var system: String
    var turns: [ChatTurn]
}

struct ChatResult {
    /// The model that actually answered (can differ from the requested one, e.g. after a refusal fallback).
    var model: String
    var usage = TokenUsage()
    var stopReason: String?
    var refused = false
    var anthropicBlocks: [[String: Any]]?
    var reasoning: String?
}

enum ChatEvent {
    case text(String)
    case finished(ChatResult)
}

protocol ChatClient {
    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error>
    func listModels() async throws -> [ModelInfo]
}

enum AIError: LocalizedError {
    case missingKey(String)
    case http(Int, String)
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .missingKey(let provider): return "No API key for \(provider). Add one in Settings → AI."
        case .http(let status, let message): return "The server returned an error (\(status)): \(message)"
        case .badResponse(let detail): return "Unexpected response: \(detail)"
        }
    }
}

// MARK: HTTP helpers

enum HTTP {
    static func request(_ url: String, method: String = "GET", headers: [String: String], body: [String: Any]? = nil) throws -> URLRequest {
        guard let url = URL(string: url) else { throw AIError.badResponse("invalid URL \(url)") }
        var request = URLRequest(url: url, timeoutInterval: 600)
        request.httpMethod = method
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return request
    }

    static func json(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw AIError.http(status, errorMessage(in: data)) }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIError.badResponse(String(decoding: data.prefix(200), as: UTF8.self))
        }
        return object
    }

    /// Server-sent events: yields the JSON of each `data:` line.
    static func events(_ request: URLRequest) -> AsyncThrowingStream<[String: Any], Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard (200..<300).contains(status) else {
                        var body = Data()
                        for try await byte in bytes { body.append(byte) }
                        throw AIError.http(status, errorMessage(in: body))
                    }
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { continue }
                        if let error = object["error"] as? [String: Any] {
                            throw AIError.http(status, error["message"] as? String ?? "\(error)")
                        }
                        continuation.yield(object)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Pulls a readable message out of the error bodies the providers send.
    static func errorMessage(in data: Data) -> String {
        let object = try? JSONSerialization.jsonObject(with: data)
        let dictionary = (object as? [String: Any]) ?? (object as? [[String: Any]])?.first
        if let error = dictionary?["error"] as? [String: Any], let message = error["message"] as? String { return message }
        if let message = dictionary?["message"] as? String { return message }
        let text = String(decoding: data.prefix(300), as: UTF8.self)
        return text.isEmpty ? "no details" : text
    }
}

private func int(_ value: Any?) -> Int { (value as? NSNumber)?.intValue ?? 0 }

// MARK: Claude (Anthropic Messages API)

struct AnthropicClient: ChatClient {
    let apiKey: String
    var baseURL = "https://api.anthropic.com"
    private static let version = "2026-10-21"

    /// Models that accept server-side refusal fallbacks (`fallbacks: "default"`).
    private static let fallbackModels: Set<String> = ["claude-opus-5-5", "claude-opus-5", "claude-fable-5-1", "claude-sonnet-5-5"]

    private var headers: [String: String] { ["x-api-key": apiKey, "anthropic-version": Self.version] }

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        var body: [String: Any] = [
            "model": request.model,
            "max_tokens": 64000,
            "stream": true,
            "system": request.system,
            "messages": request.turns.map(message),
            // Caches the conversation prefix (including the image) so follow-up questions are cheaper.
            "cache_control": ["type": "ephemeral"],
        ]
        var headers = headers
        if Self.fallbackModels.contains(request.model) {
            // If a safety classifier declines, Anthropic retries on the model it recommends for that case.
            body["fallbacks"] = "default"
            headers["anthropic-beta"] = "server-side-fallback-2026-07-01"
        }

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let urlRequest = try HTTP.request(baseURL + "/v1/messages", method: "POST", headers: headers, body: body)
                    var result = ChatResult(model: request.model)
                    var blocks: [[String: Any]] = []
                    for try await event in HTTP.events(urlRequest) {
                        switch event["type"] as? String {
                        case "message_start":
                            let message = event["message"] as? [String: Any]
                            result.model = message?["model"] as? String ?? request.model
                            apply(message?["usage"] as? [String: Any], to: &result.usage)
                        case "content_block_start":
                            blocks.append(event["content_block"] as? [String: Any] ?? [:])
                        case "content_block_delta":
                            let index = int(event["index"])
                            guard let delta = event["delta"] as? [String: Any], blocks.indices.contains(index) else { continue }
                            switch delta["type"] as? String {
                            case "text_delta":
                                let text = delta["text"] as? String ?? ""
                                blocks[index]["text"] = (blocks[index]["text"] as? String ?? "") + text
                                continuation.yield(.text(text))
                            case "thinking_delta":
                                blocks[index]["thinking"] = (blocks[index]["thinking"] as? String ?? "") + (delta["thinking"] as? String ?? "")
                            case "signature_delta":
                                blocks[index]["signature"] = delta["signature"]
                            default:
                                break
                            }
                        case "message_delta":
                            if let delta = event["delta"] as? [String: Any], let stop = delta["stop_reason"] as? String {
                                result.stopReason = stop
                            }
                            apply(event["usage"] as? [String: Any], to: &result.usage)
                        default:
                            break
                        }
                    }
                    result.refused = result.stopReason == "refusal"
                    result.anthropicBlocks = Self.replayable(blocks)
                    continuation.yield(.finished(result))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func listModels() async throws -> [ModelInfo] {
        let response = try await HTTP.json(HTTP.request(baseURL + "/v1/models?limit=100", headers: headers))
        return (response["data"] as? [[String: Any]] ?? []).compactMap { ($0["id"] as? String).map { ModelInfo(id: $0) } }
    }

    private func message(_ turn: ChatTurn) -> [String: Any] {
        if turn.role == .assistant {
            return ["role": "assistant", "content": turn.anthropicBlocks ?? [["type": "text", "text": turn.text]]]
        }
        var content: [[String: Any]] = []
        if let image = turn.image {
            content.append(["type": "image", "source": ["type": "base64", "media_type": image.mimeType, "data": image.base64]])
        }
        content.append(["type": "text", "text": turn.text])
        return ["role": "user", "content": content]
    }

    /// Usage arrives in pieces (message_start, then cumulative output in message_delta); keep the largest values.
    private func apply(_ usage: [String: Any]?, to total: inout TokenUsage) {
        guard let usage else { return }
        total.input = max(total.input, int(usage["input_tokens"]))
        total.cacheRead = max(total.cacheRead, int(usage["cache_read_input_tokens"]))
        total.cacheWrite = max(total.cacheWrite, int(usage["cache_creation_input_tokens"]))
        total.output = max(total.output, int(usage["output_tokens"]))
    }

    /// After a mid-answer fallback, blocks other than text before the last fallback marker must not be sent back.
    private static func replayable(_ blocks: [[String: Any]]) -> [[String: Any]] {
        guard let boundary = blocks.lastIndex(where: { $0["type"] as? String == "fallback" }) else { return blocks }
        let before = blocks[..<boundary].filter { $0["type"] as? String == "text" }
        return before + blocks[(boundary + 1)...]
    }
}

// MARK: OpenAI-compatible Chat Completions (OpenAI, DeepSeek, Moonshot, custom servers)

struct OpenAICompatibleClient: ChatClient {
    let baseURL: String
    let apiKey: String?
    /// Kimi's thinking models need their reasoning sent back with each earlier answer; DeepSeek rejects it.
    let replaysReasoning: Bool

    private var headers: [String: String] {
        apiKey.map { ["Authorization": "Bearer \($0)"] } ?? [:]
    }

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        var messages: [[String: Any]] = [["role": "system", "content": request.system]]
        for turn in request.turns {
            if turn.role == .assistant {
                var message: [String: Any] = ["role": "assistant", "content": turn.text]
                if replaysReasoning, let reasoning = turn.reasoning { message["reasoning_content"] = reasoning }
                messages.append(message)
            } else if let image = turn.image {
                messages.append(["role": "user", "content": [
                    ["type": "image_url", "image_url": ["url": "data:\(image.mimeType);base64,\(image.base64)"]],
                    ["type": "text", "text": turn.text],
                ]])
            } else {
                messages.append(["role": "user", "content": turn.text])
            }
        }
        let body: [String: Any] = [
            "model": request.model,
            "messages": messages,
            "stream": true,
            "stream_options": ["include_usage": true],
        ]

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let urlRequest = try HTTP.request(endpoint("chat/completions"), method: "POST", headers: headers, body: body)
                    var result = ChatResult(model: request.model)
                    var reasoning = ""
                    for try await chunk in HTTP.events(urlRequest) {
                        if let model = chunk["model"] as? String, !model.isEmpty { result.model = model }
                        if let choice = (chunk["choices"] as? [[String: Any]])?.first {
                            let delta = choice["delta"] as? [String: Any]
                            if let text = delta?["content"] as? String, !text.isEmpty {
                                continuation.yield(.text(text))
                            }
                            if let thought = delta?["reasoning_content"] as? String { reasoning += thought }
                            if let finish = choice["finish_reason"] as? String { result.stopReason = finish }
                        }
                        if let usage = chunk["usage"] as? [String: Any] { result.usage = Self.usage(usage) }
                    }
                    result.refused = result.stopReason == "content_filter"
                    result.reasoning = reasoning.isEmpty ? nil : reasoning
                    continuation.yield(.finished(result))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func listModels() async throws -> [ModelInfo] {
        let response = try await HTTP.json(HTTP.request(endpoint("models"), headers: headers))
        return (response["data"] as? [[String: Any]] ?? []).compactMap { model in
            guard let id = model["id"] as? String else { return nil }
            // DeepSeek lists input_modalities, Kimi supports_image_in; others say nothing.
            let modalities = model["input_modalities"] as? [String]
            let vision = (model["supports_image_in"] as? Bool) ?? modalities.map { $0.contains("image") }
            return ModelInfo(id: id, acceptsImages: vision)
        }.sorted { $0.id < $1.id }
    }

    private func endpoint(_ path: String) -> String {
        (baseURL.hasSuffix("/") ? baseURL : baseURL + "/") + path
    }

    /// Prompt tokens include cached ones; providers report the cached part under different names.
    private static func usage(_ usage: [String: Any]) -> TokenUsage {
        let prompt = int(usage["prompt_tokens"])
        let details = usage["prompt_tokens_details"] as? [String: Any]
        let cached = max(int(details?["cached_tokens"]), int(usage["prompt_cache_hit_tokens"]), int(usage["cached_tokens"]))
        return TokenUsage(input: max(0, prompt - cached), cacheRead: cached, output: int(usage["completion_tokens"]))
    }
}

// MARK: Google Gemini

struct GeminiClient: ChatClient {
    let apiKey: String
    var baseURL = "https://generativelanguage.googleapis.com/v1beta"

    private var headers: [String: String] { ["x-goog-api-key": apiKey] }

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        let contents: [[String: Any]] = request.turns.map { turn in
            var parts: [[String: Any]] = []
            if let image = turn.image {
                parts.append(["inline_data": ["mime_type": image.mimeType, "data": image.base64]])
            }
            parts.append(["text": turn.text])
            return ["role": turn.role == .user ? "user" : "model", "parts": parts]
        }
        let body: [String: Any] = [
            "system_instruction": ["parts": [["text": request.system]]],
            "contents": contents,
        ]

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // The model name is user-editable: encode it so it can't change the request path.
                    let model = request.model.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(.init(charactersIn: "-._"))) ?? ""
                    let url = "\(baseURL)/models/\(model):streamGenerateContent?alt=sse"
                    let urlRequest = try HTTP.request(url, method: "POST", headers: headers, body: body)
                    var result = ChatResult(model: request.model)
                    for try await chunk in HTTP.events(urlRequest) {
                        if let model = chunk["modelVersion"] as? String { result.model = model }
                        if let candidate = (chunk["candidates"] as? [[String: Any]])?.first {
                            let parts = (candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
                            for part in parts where part["thought"] as? Bool != true {
                                if let text = part["text"] as? String, !text.isEmpty { continuation.yield(.text(text)) }
                            }
                            if let finish = candidate["finishReason"] as? String { result.stopReason = finish }
                        }
                        if (chunk["promptFeedback"] as? [String: Any])?["blockReason"] != nil { result.refused = true }
                        if let usage = chunk["usageMetadata"] as? [String: Any] {
                            let cached = int(usage["cachedContentTokenCount"])
                            result.usage = TokenUsage(input: max(0, int(usage["promptTokenCount"]) - cached), cacheRead: cached,
                                                      output: int(usage["candidatesTokenCount"]) + int(usage["thoughtsTokenCount"]))
                        }
                    }
                    if ["SAFETY", "PROHIBITED_CONTENT", "BLOCKLIST"].contains(result.stopReason ?? "") { result.refused = true }
                    continuation.yield(.finished(result))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func listModels() async throws -> [ModelInfo] {
        let response = try await HTTP.json(HTTP.request("\(baseURL)/models?pageSize=200", headers: headers))
        return (response["models"] as? [[String: Any]] ?? [])
            .filter { ($0["supportedGenerationMethods"] as? [String])?.contains("generateContent") == true }
            .compactMap { ($0["name"] as? String)?.replacingOccurrences(of: "models/", with: "") }
            .sorted()
            .map { ModelInfo(id: $0) }
    }
}
