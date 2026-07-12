"""In-session live copilot suggestion lane.

Reuses the proven 3-stage proactive pipeline (gate → generate → critic) from
`utils.llm.proactive_notification`, but instead of delivering via FCM it returns a
suggestion payload that the `/v4/listen` handler pushes back on the owning WebSocket
as a `proactive_suggestion` event — the same "live copilot" the desktop renders
locally, now for phone/glasses clients. The FCM mentor path is unchanged and remains
the out-of-session fallback.

Kept import-pure per AGENTS.md: only its own in-memory MessageBuffer is constructed at
module top (same accepted pattern as mentor_notifications); no clients / IO / env reads.
"""

import time
from typing import Any, Dict, List, Optional

from database import redis_db
from database.goals import get_user_goals
from database.notifications import get_mentor_notification_frequency
from utils.llm.proactive_notification import (
    evaluate_relevance,
    generate_notification,
    validate_notification,
    FREQUENCY_TO_BASE_THRESHOLD,
)
from utils.llm.usage_tracker import track_usage, Features
from utils.llms.memory import get_prompt_memories
from utils.mentor_notifications import MessageBuffer, MIN_NEW_SEGMENTS_FOR_ANALYSIS
import logging

logger = logging.getLogger(__name__)

# Live cadence: much tighter than the FCM mentor path (5 min). One suggestion per ~90s.
COPILOT_RATE_LIMIT_SECONDS = 90
_COPILOT_APP_ID = "copilot_live"

# Dedicated buffer so we never share/consume the mentor buffer's state.
_copilot_buffer = MessageBuffer()


def _accumulate(uid: str, segments: List[Dict[str, Any]]) -> Optional[List[Dict[str, Any]]]:
    """Buffer incoming transcript segments; return the accumulated conversation once
    enough new context has arrived since the last evaluation, else None. Mirrors the
    buffering half of mentor_notifications.process_mentor_notification, on our own buffer."""
    current_time = time.time()
    buffer_data = _copilot_buffer.get_buffer(uid)

    for segment in segments:
        text = (segment.get("text") or "").strip()
        if not text:
            continue
        timestamp = segment.get("start", 0) or current_time
        is_user = segment.get("is_user", False)

        can_append = (
            buffer_data["messages"]
            and abs(buffer_data["messages"][-1]["timestamp"] - timestamp) < 2.0
            and buffer_data["messages"][-1].get("is_user") == is_user
        )
        if can_append:
            buffer_data["messages"][-1]["text"] += " " + text
        else:
            buffer_data["messages"].append({"text": text, "timestamp": timestamp, "is_user": is_user})

    new_message_count = len(buffer_data["messages"]) - buffer_data.get("messages_at_last_analysis", 0)
    if new_message_count >= MIN_NEW_SEGMENTS_FOR_ANALYSIS:
        sorted_messages = sorted(buffer_data["messages"], key=lambda x: x["timestamp"])
        buffer_data["last_analysis_time"] = current_time
        buffer_data["messages_at_last_analysis"] = len(buffer_data["messages"])
        return sorted_messages
    return None


def _rate_limited(uid: str) -> bool:
    sent_at = redis_db.get_proactive_noti_sent_at(uid, _COPILOT_APP_ID)
    return bool(sent_at and time.time() - sent_at < COPILOT_RATE_LIMIT_SECONDS)


def evaluate_copilot_suggestion(uid: str, segments: List[Dict[str, Any]]) -> Optional[Dict[str, Any]]:
    """Run the live copilot lane for a batch of transcript segments.

    Returns a suggestion dict {suggestion, headline, category, confidence, scenario} when a
    high-value suggestion is ready to push on the live WebSocket, else None. Safe to call on
    every transcript batch — it self-debounces and self-rate-limits, and never raises.
    """
    try:
        # Gate on the user's proactive frequency setting (0 = off) and our own cadence.
        frequency = get_mentor_notification_frequency(uid)
        if not frequency:
            return None
        base_threshold = FREQUENCY_TO_BASE_THRESHOLD.get(frequency)
        if base_threshold is None:
            return None
        if _rate_limited(uid):
            return None

        conversation_messages = _accumulate(uid, segments)
        if not conversation_messages:
            return None

        # Lightweight context (skip vector RAG for latency — this is the live lane).
        try:
            user_name, user_facts = get_prompt_memories(uid)
        except Exception:
            user_name, user_facts = "User", ""
        try:
            goals = get_user_goals(uid, limit=3)
        except Exception:
            goals = []

        # ── Stage 1: gate ───────────────────────────────────────────────
        with track_usage(uid, Features.PROACTIVE_NOTIFICATION):
            relevance = evaluate_relevance(
                user_name=user_name,
                user_facts=user_facts,
                goals=goals,
                current_messages=conversation_messages,
                recent_notifications=[],
            )
        if not relevance.is_relevant or relevance.relevance_score < base_threshold:
            return None

        # ── Stage 2: generate ───────────────────────────────────────────
        with track_usage(uid, Features.PROACTIVE_NOTIFICATION):
            draft = generate_notification(
                user_name=user_name,
                user_facts=user_facts,
                goals=goals,
                past_conversations_str="",
                current_messages=conversation_messages,
                recent_notifications=[],
                frequency=frequency,
                gate_reasoning=relevance.reasoning,
                output_language="en",
            )
        text = (draft.notification_text or "").strip()
        if len(text) < 5 or draft.confidence < base_threshold:
            return None

        # ── Stage 3: critic ─────────────────────────────────────────────
        with track_usage(uid, Features.PROACTIVE_NOTIFICATION):
            validation = validate_notification(
                user_name=user_name,
                notification_text=text,
                draft_reasoning=draft.reasoning,
                current_messages=conversation_messages,
                goals=goals,
                output_language="en",
            )
        if not validation.approved:
            return None

        # ── Passed: stamp rate limit and return the payload ─────────────
        redis_db.set_proactive_noti_sent_at(
            uid, app_id=_COPILOT_APP_ID, ts=int(time.time()), ttl=COPILOT_RATE_LIMIT_SECONDS
        )
        if len(text) > 150:
            text = text[:150]
        return {
            "suggestion": text,
            "headline": (draft.reasoning or "")[:60] or None,
            "category": draft.category,
            "confidence": round(float(draft.confidence), 2),
            "scenario": "meeting",
        }
    except Exception as e:
        logger.error(f"copilot_live evaluate_failed uid={uid} error={e}")
        return None
