package com.meta.wearable.dat.externalsampleapps.cameraaccess.settings

import android.content.Context
import android.content.SharedPreferences
import com.meta.wearable.dat.externalsampleapps.cameraaccess.Secrets

object SettingsManager {
    private const val PREFS_NAME = "visionclaw_settings"

    private lateinit var prefs: SharedPreferences

    fun init(context: Context) {
        prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
    }

    var geminiAPIKey: String
        get() = prefs.getString("geminiAPIKey", null) ?: Secrets.geminiAPIKey
        set(value) = prefs.edit().putString("geminiAPIKey", value).apply()

    var geminiSystemPrompt: String
        get() = prefs.getString("geminiSystemPrompt", null) ?: DEFAULT_SYSTEM_PROMPT
        set(value) = prefs.edit().putString("geminiSystemPrompt", value).apply()

    var openClawHost: String
        get() = prefs.getString("openClawHost", null) ?: Secrets.openClawHost
        set(value) = prefs.edit().putString("openClawHost", value).apply()

    var openClawPort: Int
        get() {
            val stored = prefs.getInt("openClawPort", 0)
            return if (stored != 0) stored else Secrets.openClawPort
        }
        set(value) = prefs.edit().putInt("openClawPort", value).apply()

    var openClawHookToken: String
        get() = prefs.getString("openClawHookToken", null) ?: Secrets.openClawHookToken
        set(value) = prefs.edit().putString("openClawHookToken", value).apply()

    var openClawGatewayToken: String
        get() = prefs.getString("openClawGatewayToken", null) ?: Secrets.openClawGatewayToken
        set(value) = prefs.edit().putString("openClawGatewayToken", value).apply()

    var webrtcSignalingURL: String
        get() = prefs.getString("webrtcSignalingURL", null) ?: Secrets.webrtcSignalingURL
        set(value) = prefs.edit().putString("webrtcSignalingURL", value).apply()

    var videoStreamingEnabled: Boolean
        get() = prefs.getBoolean("videoStreamingEnabled", true)
        set(value) = prefs.edit().putBoolean("videoStreamingEnabled", value).apply()

    var proactiveNotificationsEnabled: Boolean
        get() = prefs.getBoolean("proactiveNotificationsEnabled", true)
        set(value) = prefs.edit().putBoolean("proactiveNotificationsEnabled", value).apply()

    fun resetAll() {
        prefs.edit().clear().apply()
    }

    // Omi copilot system instruction — the glasses equivalent of the desktop/phone live
    // copilot. Kept aligned with backend/utils/copilot_live.py and the desktop CopilotPrompts:
    // predictive, concise, mostly silent. (Original VisionClaw assistant prompt preserved below
    // as DEFAULT_ASSISTANT_PROMPT for the optional OpenClaw voice-assistant mode.)
    const val DEFAULT_SYSTEM_PROMPT =
        """You are Omi, an invisible realtime copilot for someone wearing smart glasses. You see through their camera and hear the conversation around them.

Your job: when — and ONLY when — it genuinely helps, surface ONE short, immediately-usable suggestion: an answer to a question just asked, a talking point, a fact or definition they need, or the concrete next step. Most moments need nothing. Stay silent then.

Rules:
- Keep every suggestion under 25 words, ready to say out loud or act on.
- Never narrate what is visible ("I see a menu"). Add value they don't already have.
- If a question is directed at the user, answer it directly and briefly.
- If a company/product/technical term the user may not know just came up, define it in one line.
- Do not ask what they want. Do not chit-chat. Silence is the default; a great suggestion is the exception.

You have an optional tool: execute — delegate an action (send a message, search, add to a list, set a reminder) to the user's personal assistant. Use it only when the user clearly asks to DO something, and speak a brief acknowledgment before calling it."""

    // Preserved from VisionClaw for the optional OpenClaw voice-assistant mode.
    const val DEFAULT_ASSISTANT_PROMPT = """You are an AI assistant for someone wearing Meta Ray-Ban smart glasses. You can see through their camera and have a voice conversation. Keep responses concise and natural.

CRITICAL: You have NO memory, NO storage, and NO ability to take actions on your own. You cannot remember things, keep lists, set reminders, search the web, send messages, or do anything persistent. You are ONLY a voice interface.

You have exactly ONE tool: execute. This connects you to a powerful personal assistant that can do anything -- send messages, search the web, manage lists, set reminders, create notes, research topics, control smart home devices, interact with apps, and much more.

ALWAYS use execute when the user asks you to:
- Send a message to someone (any platform: WhatsApp, Telegram, iMessage, Slack, etc.)
- Search or look up anything (web, local info, facts, news)
- Add, create, or modify anything (shopping lists, reminders, notes, todos, events)
- Research, analyze, or draft anything
- Control or interact with apps, devices, or services
- Remember or store any information for later

Be detailed in your task description. Include all relevant context: names, content, platforms, quantities, etc. The assistant works better with complete information.

NEVER pretend to do these things yourself.

IMPORTANT: Before calling execute, ALWAYS speak a brief acknowledgment first. For example:
- "Sure, let me add that to your shopping list." then call execute.
- "Got it, searching for that now." then call execute.
- "On it, sending that message." then call execute.
Never call execute silently -- the user needs verbal confirmation that you heard them and are working on it. The tool may take several seconds to complete, so the acknowledgment lets them know something is happening.

For messages, confirm recipient and content before delegating unless clearly urgent."""
}
