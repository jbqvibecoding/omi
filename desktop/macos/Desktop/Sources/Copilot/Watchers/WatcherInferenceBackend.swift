import Foundation

/// Pluggable inference backend for watcher agents, so a watcher can run on the cloud
/// Gemini path (default) or a fully-local Ollama model. Ported in spirit from Observer
/// AI's model-name → server abstraction: one uniform "system + user (+ images)" call.
protocol WatcherInferenceBackend {
    func complete(systemPrompt: String, userPrompt: String, images: [Data]) async throws -> String
}

enum WatcherInferenceError: Error {
    case badResponse(String)
}

/// Cloud path — wraps the existing GeminiClient (routes through the omi backend proxy).
final class GeminiInferenceBackend: WatcherInferenceBackend {
    private var client: GeminiClient?
    private let modelId: String?

    /// A minimal `{output: string}` schema so the vision path returns parseable text.
    private static let outputSchema = GeminiRequest.GenerationConfig.ResponseSchema(
        type: "object",
        properties: [
            "output": .init(type: "string", enum: nil, description: "Your full response for this observation.")
        ],
        required: ["output"]
    )
    private struct Output: Decodable { let output: String }

    init(modelId: String? = nil) {
        self.modelId = modelId
    }

    func complete(systemPrompt: String, userPrompt: String, images: [Data]) async throws -> String {
        let client = try cachedClient()
        if let image = images.first {
            let json = try await client.sendRequest(
                prompt: userPrompt, imageData: image, systemPrompt: systemPrompt,
                responseSchema: Self.outputSchema, thinkingBudget: 0)
            return try JSONDecoder().decode(Output.self, from: Data(json.utf8)).output
        }
        return try await client.sendTextRequest(
            prompt: userPrompt, systemPrompt: systemPrompt, maxRetries: 1, timeout: 60, thinkingBudget: 0)
    }

    private func cachedClient() throws -> GeminiClient {
        if let client { return client }
        let created = try GeminiClient(
            model: modelId ?? ModelQoS.Gemini.proactive, fallbackModel: "gemini-2.5-flash")
        client = created
        return created
    }
}

/// Local path — talks to Ollama's OpenAI-compatible endpoint (no network leaves the
/// machine, no auth). Base URL from `OLLAMA_BASE_URL` (default http://localhost:11434/).
final class OllamaInferenceBackend: WatcherInferenceBackend {
    private let modelId: String

    init(modelId: String) {
        self.modelId = modelId
    }

    private static var baseURL: String {
        if let cString = getenv("OLLAMA_BASE_URL"), let url = String(validatingUTF8: cString), !url.isEmpty {
            return url.hasSuffix("/") ? url : url + "/"
        }
        return "http://localhost:11434/"
    }

    func complete(systemPrompt: String, userPrompt: String, images: [Data]) async throws -> String {
        guard let url = URL(string: "\(Self.baseURL)v1/chat/completions") else {
            throw WatcherInferenceError.badResponse("bad Ollama URL")
        }

        var userContent: [[String: Any]] = [["type": "text", "text": userPrompt]]
        for image in images {
            userContent.append([
                "type": "image_url",
                "image_url": ["url": "data:image/jpeg;base64,\(image.base64EncodedString())"],
            ])
        }

        let body: [String: Any] = [
            "model": modelId,
            "stream": false,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userContent],
            ],
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw WatcherInferenceError.badResponse("Ollama HTTP \(http.statusCode)")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = json["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any],
            let content = message["content"] as? String
        else {
            throw WatcherInferenceError.badResponse("unparseable Ollama response")
        }
        return content
    }
}

/// Any endpoint the user can describe with a curl command.
///
/// This exists so omi doesn't need an adapter per provider: every provider's docs open
/// with a curl example, so pasting it is the shortest path from "I have a key" to "my
/// watcher runs on this model". Non-streaming only — a watcher reads the whole response
/// before it decides anything, so SSE would buy nothing and cost a parser.
final class CustomEndpointBackend: WatcherInferenceBackend {
    private let template: String
    private let contentPath: String
    private let timeout: TimeInterval = 90

    init(template: String, contentPath: String) {
        self.template = template
        self.contentPath = contentPath
    }

    func complete(systemPrompt: String, userPrompt: String, images: [Data]) async throws -> String {
        let parsed = try CurlTemplate.parse(template)
        let filled = parsed.filled(
            systemPrompt: systemPrompt, userPrompt: userPrompt,
            imageBase64: images.first?.base64EncodedString())
        var request = try filled.urlRequest()
        request.timeoutInterval = timeout

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            // Endpoint errors are usually a wrong key or model name, and the body says
            // which — but it can also echo the prompt, so keep it short.
            let head = String(decoding: data.prefix(300), as: UTF8.self)
            throw WatcherInferenceError.badResponse("HTTP \(http.statusCode): \(head)")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            throw WatcherInferenceError.badResponse("response wasn't JSON")
        }
        guard let text = JSONPath.string(in: json, path: contentPath) else {
            throw WatcherInferenceError.badResponse(
                "nothing at `\(contentPath)` — check the answer path against a real response")
        }
        return text
    }
}

/// Builds the backend for a watcher based on its configured kind + model.
enum WatcherInferenceBackendFactory {
    static func make(for watcher: WatcherAgent) -> WatcherInferenceBackend {
        switch watcher.effectiveBackend {
        case .ollama:
            return OllamaInferenceBackend(modelId: watcher.effectiveModelId ?? "gemma3")
        case .custom:
            return CustomEndpointBackend(
                template: watcher.curlTemplate ?? "",
                contentPath: watcher.effectiveResponseContentPath)
        case .gemini:
            return GeminiInferenceBackend(modelId: watcher.modelId)
        }
    }
}
