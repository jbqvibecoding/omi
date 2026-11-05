import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'package:omi/backend/schema/message_event.dart';

/// Client-side Gemini Live copilot input path — ported from VisionClaw's
/// GeminiLiveService (Kotlin). Streams mic PCM (16kHz) + camera JPEG frames (~1fps)
/// to the Gemini Live WebSocket and turns the model's text output into
/// [ProactiveSuggestionEvent]s surfaced through the same copilot suggestion UI.
///
/// This is the "Gemini Live as input" path (phone camera route). The service is
/// transport-only: the caller feeds it audio/frame bytes (from the camera + mic)
/// and listens to [suggestions]. Auth is BYOK/dev-key for now (see [apiKey]) — wire
/// a backend-minted ephemeral token later, matching the desktop RealtimeHub.
///
/// Client scaffolding — pending local flutter analyze/build verification.
class GeminiLiveCopilotService {
  static const String _wsBaseUrl =
      'wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent';
  static const String _model = 'models/gemini-2.5-flash-native-audio-preview-12-2025';

  /// System instruction shaping the copilot's behavior. Keep aligned with the
  /// desktop CopilotPrompts and the backend copilot lane (predictive, concise).
  static const String defaultSystemInstruction =
      'You are an invisible realtime copilot. You see the user\'s camera and hear the '
      'conversation. When — and only when — it genuinely helps, output ONE short, '
      'immediately-usable suggestion (an answer, a talking point, a next step) in under '
      '30 words. Most moments need nothing; stay silent then. Never narrate what is visible.';

  final String apiKey;
  final String systemInstruction;
  final String scenario;

  WebSocketChannel? _channel;
  StreamSubscription? _sub;
  bool _ready = false;

  final _suggestionsController = StreamController<ProactiveSuggestionEvent>.broadcast();

  /// Emits a suggestion each time the model produces a complete text turn.
  Stream<ProactiveSuggestionEvent> get suggestions => _suggestionsController.stream;

  bool get isReady => _ready;

  // Accumulates streamed text parts until the model signals turn completion.
  final StringBuffer _pendingText = StringBuffer();

  GeminiLiveCopilotService({
    required this.apiKey,
    this.systemInstruction = defaultSystemInstruction,
    this.scenario = 'meeting',
  });

  Future<bool> connect() async {
    if (apiKey.isEmpty) return false;
    try {
      _channel = IOWebSocketChannel.connect(Uri.parse('$_wsBaseUrl?key=$apiKey'));
      _sub = _channel!.stream.listen(
        _handleMessage,
        onError: (_) => _ready = false,
        onDone: () => _ready = false,
      );
      _sendSetup();
      return true;
    } catch (_) {
      _ready = false;
      return false;
    }
  }

  void disconnect() {
    _ready = false;
    _sub?.cancel();
    _channel?.sink.close();
    _channel = null;
  }

  Future<void> dispose() async {
    disconnect();
    await _suggestionsController.close();
  }

  /// Feed a chunk of mic audio (PCM16, 16kHz, mono).
  void sendAudio(Uint8List pcm16) {
    if (!_ready) return;
    _send({
      'realtimeInput': {
        'audio': {'mimeType': 'audio/pcm;rate=16000', 'data': base64Encode(pcm16)},
      },
    });
  }

  /// Feed a camera frame as JPEG bytes (call at ~1fps).
  void sendVideoFrame(Uint8List jpeg) {
    if (!_ready) return;
    _send({
      'realtimeInput': {
        'video': {'mimeType': 'image/jpeg', 'data': base64Encode(jpeg)},
      },
    });
  }

  // MARK: - Internals

  void _sendSetup() {
    _send({
      'setup': {
        'model': _model,
        'generationConfig': {
          // Text output — surfaced as suggestion cards (not spoken).
          'responseModalities': ['TEXT'],
          'thinkingConfig': {'thinkingBudget': 0},
        },
        'systemInstruction': {
          'parts': [
            {'text': systemInstruction},
          ],
        },
        'realtimeInputConfig': {
          'automaticActivityDetection': {
            'disabled': false,
            'startOfSpeechSensitivity': 'START_SENSITIVITY_HIGH',
            'endOfSpeechSensitivity': 'END_SENSITIVITY_LOW',
            'silenceDurationMs': 500,
            'prefixPaddingMs': 40,
          },
          'activityHandling': 'START_OF_ACTIVITY_INTERRUPTS',
          'turnCoverage': 'TURN_INCLUDES_ALL_INPUT',
        },
        'contextWindowCompression': {
          'slidingWindow': {'targetTokens': 80000},
        },
        'inputAudioTranscription': {},
      },
    });
  }

  void _send(Map<String, dynamic> payload) {
    try {
      _channel?.sink.add(jsonEncode(payload));
    } catch (_) {
      // fail-open: transport errors just drop the frame/chunk
    }
  }

  void _handleMessage(dynamic raw) {
    try {
      final text = raw is String ? raw : utf8.decode(raw as List<int>);
      final json = jsonDecode(text) as Map<String, dynamic>;

      if (json.containsKey('setupComplete')) {
        _ready = true;
        return;
      }

      final serverContent = json['serverContent'] as Map<String, dynamic>?;
      if (serverContent != null) {
        final modelTurn = serverContent['modelTurn'] as Map<String, dynamic>?;
        final parts = (modelTurn?['parts'] as List?) ?? const [];
        for (final part in parts) {
          final t = (part is Map && part['text'] is String) ? part['text'] as String : null;
          if (t != null && t.isNotEmpty) _pendingText.write(t);
        }
        final complete = serverContent['turnComplete'] == true || serverContent['generationComplete'] == true;
        if (complete) _flushPendingSuggestion();
      }
    } catch (_) {
      // ignore malformed frames
    }
  }

  void _flushPendingSuggestion() {
    final full = _pendingText.toString().trim();
    _pendingText.clear();
    if (full.isEmpty) return;
    final headline = full.split(RegExp(r'[.!?\n]')).first.trim();
    _suggestionsController.add(
      ProactiveSuggestionEvent(
        suggestion: full,
        headline: headline.isNotEmpty && headline.length <= 48 ? headline : null,
        category: 'copilot_live',
        scenario: scenario,
      ),
    );
  }
}
