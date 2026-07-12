import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:omi/backend/schema/message_event.dart';
import 'package:omi/utils/l10n_extensions.dart';

/// A single live-copilot suggestion card, surfaced during recording as the
/// phone/glasses parity of the desktop live copilot. Dynamic content (headline,
/// suggestion) comes from the backend event; only the action labels are localized.
class CopilotSuggestionCard extends StatelessWidget {
  final ProactiveSuggestionEvent event;
  final VoidCallback onDismiss;

  const CopilotSuggestionCard({super.key, required this.event, required this.onDismiss});

  @override
  Widget build(BuildContext context) {
    final headline = (event.headline ?? '').trim();
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.06),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withOpacity(0.10)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.auto_awesome, size: 16, color: Colors.white),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  headline.isNotEmpty ? headline : 'Copilot',
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 14),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close, size: 16, color: Colors.white54),
                visualDensity: VisualDensity.compact,
                onPressed: onDismiss,
                tooltip: context.l10n.close,
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            event.suggestion,
            style: TextStyle(color: Colors.white.withOpacity(0.85), fontSize: 13),
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton.icon(
                icon: const Icon(Icons.copy, size: 14, color: Colors.white),
                label: Text(context.l10n.copy, style: const TextStyle(color: Colors.white, fontSize: 12)),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: event.suggestion));
                  onDismiss();
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// A stacked list of the current copilot suggestions. Drop this into the recording
/// UI (e.g. above the transcript) and pass the controller's `copilotSuggestions`.
class CopilotSuggestionsOverlay extends StatelessWidget {
  final List<ProactiveSuggestionEvent> suggestions;
  final void Function(ProactiveSuggestionEvent) onDismiss;

  const CopilotSuggestionsOverlay({super.key, required this.suggestions, required this.onDismiss});

  @override
  Widget build(BuildContext context) {
    if (suggestions.isEmpty) return const SizedBox.shrink();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: suggestions
          .map((s) => CopilotSuggestionCard(event: s, onDismiss: () => onDismiss(s)))
          .toList(),
    );
  }
}
