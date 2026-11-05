import Foundation

/// A curl command the user pasted, turned into a request we can actually send.
///
/// The point of accepting curl at all: every model provider's docs open with a curl
/// example. Pasting it is the shortest path from "I have an API key" to "my watcher runs
/// on this model", and it means omi doesn't need an adapter written per provider.
///
/// Deliberately narrow. It understands `-X`, `-H`, `-d`/`--data`/`--data-raw` and the URL,
/// and **fails loudly on anything else** rather than guessing. A parser that silently
/// ignores a flag produces a request that is subtly wrong, which is far worse to debug
/// than a parse error at paste time.
struct CurlTemplate: Equatable {
    let url: String
    let method: String
    let headers: [String: String]
    let body: String?

    /// Placeholders the user writes into the curl body.
    static let systemToken = "{{SYSTEM}}"
    static let promptToken = "{{PROMPT}}"
    static let imageToken = "{{IMAGE}}"

    enum ParseError: LocalizedError, Equatable {
        case notCurl
        case noURL
        case unterminatedQuote
        case unsupportedFlag(String)
        case missingValue(String)
        case malformedHeader(String)

        var errorDescription: String? {
            switch self {
            case .notCurl:
                return "This doesn't start with `curl`. Paste the whole command."
            case .noURL:
                return "No URL found. The command needs the endpoint to call."
            case .unterminatedQuote:
                return "A quote is never closed — check for a missing \" or '."
            case let .unsupportedFlag(flag):
                return
                    "`\(flag)` isn't supported. Keep it to the URL, -X, -H and -d so the "
                    + "request omi sends matches what you pasted."
            case let .missingValue(flag):
                return "`\(flag)` is missing its value."
            case let .malformedHeader(header):
                return "Header `\(header)` isn't in `Name: value` form."
            }
        }
    }

    // MARK: - Parsing

    static func parse(_ command: String) throws -> CurlTemplate {
        let tokens = try tokenize(command)
        guard let first = tokens.first, first == "curl" else { throw ParseError.notCurl }

        var url: String?
        var method: String?
        var headers: [String: String] = [:]
        var body: String?

        var index = 1
        while index < tokens.count {
            let token = tokens[index]
            switch token {
            case "-X", "--request":
                guard index + 1 < tokens.count else { throw ParseError.missingValue(token) }
                method = tokens[index + 1].uppercased()
                index += 2
            case "-H", "--header":
                guard index + 1 < tokens.count else { throw ParseError.missingValue(token) }
                let raw = tokens[index + 1]
                guard let colon = raw.firstIndex(of: ":") else {
                    throw ParseError.malformedHeader(raw)
                }
                let name = String(raw[raw.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
                let value = String(raw[raw.index(after: colon)...])
                    .trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { throw ParseError.malformedHeader(raw) }
                headers[name] = value
                index += 2
            case "-d", "--data", "--data-raw", "--data-binary":
                guard index + 1 < tokens.count else { throw ParseError.missingValue(token) }
                body = tokens[index + 1]
                index += 2
            // Harmless in a copy-pasted example: they affect curl's own output, not the
            // request we build.
            case "-s", "--silent", "-S", "--show-error", "-L", "--location", "--compressed":
                index += 1
            default:
                if token.hasPrefix("-") {
                    throw ParseError.unsupportedFlag(token)
                }
                // A bare token is the URL. The last one wins, matching curl.
                url = token
                index += 1
            }
        }

        guard let url, !url.isEmpty else { throw ParseError.noURL }
        return CurlTemplate(
            url: url,
            // curl's own rule: a body implies POST unless told otherwise.
            method: method ?? (body != nil ? "POST" : "GET"),
            headers: headers,
            body: body)
    }

    /// Splits a shell-ish command into tokens, honoring quotes, backslash line
    /// continuations, and `\"` escapes inside double quotes.
    static func tokenize(_ command: String) throws -> [String] {
        var tokens: [String] = []
        var current = ""
        var hasCurrent = false
        var quote: Character?
        var iterator = command.startIndex

        while iterator < command.endIndex {
            let char = command[iterator]
            if let active = quote {
                if char == "\\", active == "\"", command.index(after: iterator) < command.endIndex {
                    let next = command[command.index(after: iterator)]
                    // Preserve JSON escapes; only unescape the shell-level ones.
                    if next == "\"" || next == "\\" {
                        current.append(next)
                    } else {
                        current.append(char)
                        current.append(next)
                    }
                    iterator = command.index(iterator, offsetBy: 2)
                    continue
                }
                if char == active {
                    quote = nil
                } else {
                    current.append(char)
                }
            } else if char == "\"" || char == "'" {
                quote = char
                hasCurrent = true
            } else if char == "\\" {
                // Line continuation: swallow the backslash and the newline after it.
                let next = command.index(after: iterator)
                if next < command.endIndex, command[next] == "\n" {
                    iterator = command.index(iterator, offsetBy: 2)
                    continue
                }
                current.append(char)
            } else if char.isWhitespace {
                if hasCurrent || !current.isEmpty {
                    tokens.append(current)
                    current = ""
                    hasCurrent = false
                }
            } else {
                current.append(char)
            }
            iterator = command.index(after: iterator)
        }

        if quote != nil { throw ParseError.unterminatedQuote }
        if hasCurrent || !current.isEmpty { tokens.append(current) }
        return tokens
    }

    // MARK: - Validation

    /// Placeholders present in the command. `{{PROMPT}}` is the only required one —
    /// without it the model would never see what the watcher observed.
    static func missingRequiredTokens(in command: String) -> [String] {
        command.contains(promptToken) ? [] : [promptToken]
    }

    /// Human-readable check for the editor: nil when the command is usable.
    static func validationMessage(for command: String) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Paste the curl command from your provider's docs." }
        do {
            _ = try parse(trimmed)
        } catch {
            return error.localizedDescription
        }
        let missing = missingRequiredTokens(in: trimmed)
        guard missing.isEmpty else {
            return "Add \(missing.joined(separator: ", ")) where the question should go."
        }
        return nil
    }

    // MARK: - Filling

    /// Substitute the placeholders. Values are JSON-string-escaped because the body is
    /// almost always JSON and a prompt routinely contains quotes and newlines.
    func filled(systemPrompt: String, userPrompt: String, imageBase64: String?) -> CurlTemplate {
        guard let body else { return self }
        var out = body
        out = out.replacingOccurrences(
            of: Self.systemToken, with: Self.jsonEscaped(systemPrompt))
        out = out.replacingOccurrences(of: Self.promptToken, with: Self.jsonEscaped(userPrompt))
        out = out.replacingOccurrences(of: Self.imageToken, with: imageBase64 ?? "")
        return CurlTemplate(url: url, method: method, headers: headers, body: out)
    }

    /// Escapes a string for embedding inside a JSON string literal, without the quotes.
    static func jsonEscaped(_ value: String) -> String {
        var out = ""
        out.reserveCapacity(value.count + 16)
        for char in value.unicodeScalars {
            switch char {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if char.value < 0x20 {
                    out += String(format: "\\u%04x", char.value)
                } else {
                    out.unicodeScalars.append(char)
                }
            }
        }
        return out
    }

    /// Build the URLRequest this template describes.
    func urlRequest() throws -> URLRequest {
        guard let endpoint = URL(string: url) else { throw ParseError.noURL }
        var request = URLRequest(url: endpoint)
        request.httpMethod = method
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if let body { request.httpBody = Data(body.utf8) }
        return request
    }
}

/// Reads a value out of a decoded JSON object by dotted path, e.g.
/// `choices.0.message.content`. Array indices are plain numbers.
enum JSONPath {
    static func string(in json: Any, path: String) -> String? {
        var node: Any? = json
        for component in path.split(separator: ".") {
            guard let current = node else { return nil }
            if let index = Int(component) {
                guard let array = current as? [Any], array.indices.contains(index) else {
                    return nil
                }
                node = array[index]
            } else {
                guard let dict = current as? [String: Any] else { return nil }
                node = dict[String(component)]
            }
        }
        if let text = node as? String { return text }
        // Some providers return content as an array of parts.
        if let parts = node as? [Any] {
            let joined = parts.compactMap { part -> String? in
                if let text = part as? String { return text }
                if let dict = part as? [String: Any] { return dict["text"] as? String }
                return nil
            }.joined()
            return joined.isEmpty ? nil : joined
        }
        return nil
    }
}
