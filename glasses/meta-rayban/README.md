# Omi Copilot — Meta Ray-Ban glasses (Android)

The glasses-side of the Omi live copilot: it sees through your Meta Ray-Ban camera,
hears the conversation around you, and speaks a short, useful suggestion when — and only
when — it genuinely helps. This is the wearable parity of the desktop live copilot and the
phone copilot (`app/lib/services/gemini_live_copilot_service.dart` + the backend
`proactive_suggestion` lane in `backend/utils/copilot_live.py`).

## Attribution

This app is **derived from [VisionClaw](https://github.com/jbqvibecoding/visionclaw)**
(a Meta Wearables DAT + Gemini Live sample). The Gemini Live client, DAT camera access,
and WebRTC pieces are reused largely as-is; the Omi-specific change is the copilot system
instruction (`settings/SettingsManager.kt` → `DEFAULT_SYSTEM_PROMPT`) that turns the
general voice assistant into the predictive, mostly-silent Omi copilot, aligned with the
desktop `CopilotPrompts` and the backend copilot lane. The upstream sample's README is kept
as `README_upstream.md`.

- Original `LICENSE` and third-party `NOTICE` from VisionClaw are preserved in this folder.
- Use of the **Meta Wearables Device Access Toolkit** is governed by the
  [Meta Wearables Developer Terms](https://wearables.developer.meta.com/terms) and the
  Acceptable Use Policy — see `LICENSE`.

## What it does

- **Gemini Live** — camera JPEG frames (~1fps) + mic PCM (16kHz) stream to the Gemini Live
  WebSocket; the model replies with native audio (spoken suggestions through the glasses).
- **Copilot behavior** — the system prompt keeps it silent by default and surfaces one
  concise, actionable suggestion when the moment warrants (a question directed at you, a
  term to define, a next step). It never narrates what's visible.
- **Optional OpenClaw** — the original VisionClaw `execute` tool (delegate actions to a
  personal-assistant gateway) is retained behind `DEFAULT_ASSISTANT_PROMPT`; leave it
  unconfigured to run copilot-only.

## Build

1. **Prerequisites** — Android Studio, a phone with the Meta AI / Wearables app paired to
   your Ray-Ban glasses, and access to the Meta Wearables DAT SDK (see `README_upstream.md`
   and Meta developer docs for SDK/manifest setup).
2. **Gemini key** — set your Gemini API key in the app's Settings screen (BYOK). A
   backend-minted ephemeral token (matching the desktop RealtimeHub) can replace BYOK later.
3. Open `glasses/meta-rayban` in Android Studio and run on a paired phone; grant camera and
   microphone permissions. **Phone camera mode** works without glasses for testing.

## Status

Vendored + adapted from VisionClaw; **pending local Android Studio build verification** in
this environment (no Android/Gradle toolchain here). The Omi adaptation is the copilot
system instruction; the Gemini Live protocol and DAT integration are VisionClaw's.
