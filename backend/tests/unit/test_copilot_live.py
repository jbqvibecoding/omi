"""Tests for the in-session live copilot suggestion lane (utils/copilot_live.py).

Covers:
- ProactiveSuggestionEvent construction + to_json wire shape
- Buffer debounce (no evaluation until enough new segments accumulate)
- Rate limiting (own copilot_live key, independent of mentor)
- End-to-end 3-stage pipeline returning a suggestion payload when approved
- Gate/critic rejection paths returning None

Hermetic: production functions are patched at their consumption site in
utils.copilot_live via patch.object (per AGENTS.md), auto-restored each test.
"""

from contextlib import contextmanager
from unittest.mock import MagicMock, patch

import pytest

import utils.copilot_live as copilot_live
from models.message_event import ProactiveSuggestionEvent
from utils.llm.proactive_notification import NotificationDraft, RelevanceResult, ValidationResult


@contextmanager
def _noop_usage(*args, **kwargs):
    yield


def _relevant():
    return RelevanceResult(is_relevant=True, relevance_score=0.95, reasoning="worth it", context_summary="ctx")


def _draft():
    return NotificationDraft(
        notification_text="Ask them about the Q3 budget you promised to review.",
        reasoning="You committed to reviewing it earlier.",
        confidence=0.9,
        category="productivity",
    )


def _approved():
    return ValidationResult(approved=True, reasoning="useful")


@pytest.fixture(autouse=True)
def _reset_buffer():
    # Fresh buffer each test so debounce counts are deterministic.
    copilot_live._copilot_buffer = copilot_live.MessageBuffer()
    yield


def _segments(n):
    # n distinct segments spaced >2s apart so they don't merge in the buffer.
    return [{"text": f"utterance number {i}", "start": float(i * 5), "is_user": i % 2 == 0} for i in range(n)]


def test_event_to_json_wire_shape():
    ev = ProactiveSuggestionEvent(
        suggestion="Say hello", headline="Greet", category="productivity", confidence=0.8, scenario="meeting"
    )
    j = ev.to_json()
    assert j["type"] == "proactive_suggestion"
    assert "event_type" not in j
    assert j["suggestion"] == "Say hello"
    assert j["confidence"] == 0.8


def test_debounce_returns_none_until_enough_segments():
    with patch.object(copilot_live, "get_mentor_notification_frequency", return_value=3), patch.object(
        copilot_live.redis_db, "get_proactive_noti_sent_at", return_value=None
    ):
        # Fewer than MIN_NEW_SEGMENTS_FOR_ANALYSIS -> no evaluation.
        few = copilot_live._accumulate("uid1", _segments(3))
        assert few is None


def test_frequency_off_short_circuits():
    with patch.object(copilot_live, "get_mentor_notification_frequency", return_value=0):
        assert copilot_live.evaluate_copilot_suggestion("uid1", _segments(20)) is None


def test_rate_limited_returns_none():
    import time

    with patch.object(copilot_live, "get_mentor_notification_frequency", return_value=3), patch.object(
        copilot_live.redis_db, "get_proactive_noti_sent_at", return_value=time.time()
    ):
        assert copilot_live.evaluate_copilot_suggestion("uid1", _segments(20)) is None


def test_end_to_end_returns_suggestion_when_approved():
    with patch.object(copilot_live, "get_mentor_notification_frequency", return_value=3), patch.object(
        copilot_live.redis_db, "get_proactive_noti_sent_at", return_value=None
    ), patch.object(copilot_live.redis_db, "set_proactive_noti_sent_at"), patch.object(
        copilot_live, "get_prompt_memories", return_value=("TestUser", "facts")
    ), patch.object(
        copilot_live, "get_user_goals", return_value=[]
    ), patch.object(
        copilot_live, "track_usage", _noop_usage
    ), patch.object(
        copilot_live, "evaluate_relevance", return_value=_relevant()
    ), patch.object(
        copilot_live, "generate_notification", return_value=_draft()
    ), patch.object(
        copilot_live, "validate_notification", return_value=_approved()
    ):
        result = copilot_live.evaluate_copilot_suggestion("uid1", _segments(20))
        assert result is not None
        assert result["suggestion"].startswith("Ask them about the Q3 budget")
        assert result["category"] == "productivity"
        assert result["confidence"] == 0.9
        assert result["scenario"] == "meeting"


def test_gate_rejection_returns_none():
    not_relevant = RelevanceResult(is_relevant=False, relevance_score=0.1, reasoning="nah", context_summary="ctx")
    with patch.object(copilot_live, "get_mentor_notification_frequency", return_value=3), patch.object(
        copilot_live.redis_db, "get_proactive_noti_sent_at", return_value=None
    ), patch.object(copilot_live, "get_prompt_memories", return_value=("TestUser", "facts")), patch.object(
        copilot_live, "get_user_goals", return_value=[]
    ), patch.object(
        copilot_live, "track_usage", _noop_usage
    ), patch.object(
        copilot_live, "evaluate_relevance", return_value=not_relevant
    ):
        assert copilot_live.evaluate_copilot_suggestion("uid1", _segments(20)) is None


def test_critic_rejection_returns_none():
    rejected = ValidationResult(approved=False, reasoning="too noisy")
    with patch.object(copilot_live, "get_mentor_notification_frequency", return_value=3), patch.object(
        copilot_live.redis_db, "get_proactive_noti_sent_at", return_value=None
    ), patch.object(copilot_live, "get_prompt_memories", return_value=("TestUser", "facts")), patch.object(
        copilot_live, "get_user_goals", return_value=[]
    ), patch.object(
        copilot_live, "track_usage", _noop_usage
    ), patch.object(
        copilot_live, "evaluate_relevance", return_value=_relevant()
    ), patch.object(
        copilot_live, "generate_notification", return_value=_draft()
    ), patch.object(
        copilot_live, "validate_notification", return_value=rejected
    ):
        assert copilot_live.evaluate_copilot_suggestion("uid1", _segments(20)) is None
