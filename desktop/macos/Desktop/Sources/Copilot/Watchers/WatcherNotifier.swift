import Foundation

/// Delivers watcher notifications to outbound channels via direct client-side HTTP,
/// ported from Observer AI's send* tools (no omi backend involved). Discord uses a
/// self-contained webhook URL; Telegram uses the user's bot token + chat id; Pushover
/// uses the user's app token + user key.
enum WatcherNotifier {
    /// Discord hard-caps messages ~2000 chars.
    private static let maxMessageChars = 1900

    struct Result {
        let ok: Bool
        let detail: String
    }

    @discardableResult
    static func send(
        channel: WatcherNotificationChannel, target: String, message: String
    ) async -> Result {
        let text = String(message.prefix(maxMessageChars))
        guard !target.isEmpty else { return Result(ok: false, detail: "empty target") }

        switch channel {
        case .discord:
            return await sendDiscord(webhookURL: target, message: text)
        case .telegram:
            let token = await MainActor.run { WatcherChannelSettings.shared.telegramBotToken }
            guard !token.isEmpty else { return Result(ok: false, detail: "telegram bot token not set") }
            return await sendTelegram(botToken: token, chatId: target, message: text)
        case .pushover:
            let appToken = await MainActor.run { WatcherChannelSettings.shared.pushoverAppToken }
            guard !appToken.isEmpty else { return Result(ok: false, detail: "pushover app token not set") }
            return await sendPushover(appToken: appToken, userKey: target, message: text)
        case .sms:
            return await sendViaBackend(path: "v1/tools/send-sms", body: ["to": target, "body": text])
        case .whatsapp:
            return await sendViaBackend(path: "v1/tools/send-whatsapp", body: ["to": target, "body": text])
        case .call:
            return await sendViaBackend(path: "v1/tools/call", body: ["to": target, "message": text])
        }
    }

    // MARK: - Backend-routed channels (Twilio SMS / WhatsApp / call)

    private static var backendBaseURL: String {
        if let cString = getenv("OMI_DESKTOP_API_URL"), let url = String(validatingUTF8: cString), !url.isEmpty {
            return url.hasSuffix("/") ? url : url + "/"
        }
        return "https://api.omi.me/"
    }

    private static func sendViaBackend(path: String, body: [String: String]) async -> Result {
        guard let url = URL(string: "\(backendBaseURL)\(path)") else {
            return Result(ok: false, detail: "bad backend url")
        }
        let authHeader: String
        do {
            authHeader = try await MainActor.run { AuthService.shared }.getAuthHeader()
        } catch {
            return Result(ok: false, detail: "auth unavailable")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            // The tools endpoints return a ToolResponse envelope with is_error.
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let isError = json["is_error"] as? Bool
            {
                let text = json["result_text"] as? String ?? ""
                return Result(ok: !isError, detail: text.isEmpty ? "HTTP \(code)" : text)
            }
            return Result(ok: (200..<300).contains(code), detail: "HTTP \(code)")
        } catch {
            log("WatcherNotifier: backend send error: \(error.localizedDescription)")
            return Result(ok: false, detail: error.localizedDescription)
        }
    }

    // MARK: - Channels

    private static func sendDiscord(webhookURL: String, message: String) async -> Result {
        guard let url = URL(string: webhookURL) else { return Result(ok: false, detail: "bad webhook url") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["content": message])
        return await perform(request, channel: "discord")
    }

    private static func sendTelegram(botToken: String, chatId: String, message: String) async -> Result {
        guard let url = URL(string: "https://api.telegram.org/bot\(botToken)/sendMessage") else {
            return Result(ok: false, detail: "bad telegram url")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "chat_id": chatId, "text": message,
        ])
        return await perform(request, channel: "telegram")
    }

    private static func sendPushover(appToken: String, userKey: String, message: String) async -> Result {
        guard let url = URL(string: "https://api.pushover.net/1/messages.json") else {
            return Result(ok: false, detail: "bad pushover url")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var comps = URLComponents()
        comps.queryItems = [
            URLQueryItem(name: "token", value: appToken),
            URLQueryItem(name: "user", value: userKey),
            URLQueryItem(name: "message", value: message),
        ]
        request.httpBody = comps.percentEncodedQuery?.data(using: .utf8)
        return await perform(request, channel: "pushover")
    }

    // MARK: - Transport

    private static func perform(_ request: URLRequest, channel: String) async -> Result {
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let ok = (200..<300).contains(code)
            if !ok { log("WatcherNotifier: \(channel) send failed (HTTP \(code))") }
            return Result(ok: ok, detail: "HTTP \(code)")
        } catch {
            log("WatcherNotifier: \(channel) send error: \(error.localizedDescription)")
            return Result(ok: false, detail: error.localizedDescription)
        }
    }
}
