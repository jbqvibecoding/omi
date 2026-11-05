import Foundation

/// Credentials for watcher outbound notification channels. Client-side, user-provided
/// (each user runs their own Telegram bot / Pushover app). Stored in UserDefaults for v1;
/// the bot/app tokens are sensitive — migrate to Keychain in a follow-up.
@MainActor
final class WatcherChannelSettings {
    static let shared = WatcherChannelSettings()

    private let telegramTokenKey = "watcherTelegramBotToken"
    private let pushoverTokenKey = "watcherPushoverAppToken"

    private init() {}

    /// Telegram bot token (from @BotFather). The per-action target holds the chat id.
    var telegramBotToken: String {
        get { UserDefaults.standard.string(forKey: telegramTokenKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: telegramTokenKey) }
    }

    /// Pushover application token. The per-action target holds the user key.
    var pushoverAppToken: String {
        get { UserDefaults.standard.string(forKey: pushoverTokenKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: pushoverTokenKey) }
    }

    /// Whether a channel has the global credential it needs. (Discord needs none — the
    /// target is a self-contained webhook URL.)
    func isConfigured(_ channel: WatcherNotificationChannel) -> Bool {
        switch channel {
        case .discord: return true
        case .telegram: return !telegramBotToken.isEmpty
        case .pushover: return !pushoverAppToken.isEmpty
        }
    }
}
