import os
from unittest.mock import MagicMock, patch

import pytest

from tests.unit.twilio_stub import install_phone_calls_stub, install_twilio_stub, prepare_twilio_service_import

os.environ.setdefault('TWILIO_ACCOUNT_SID', 'ACtest123')
os.environ.setdefault('TWILIO_AUTH_TOKEN', 'test_auth_token')
os.environ['TWILIO_FROM_NUMBER'] = '+15005550006'
os.environ['TWILIO_WHATSAPP_FROM'] = '+15005550006'
install_twilio_stub()
prepare_twilio_service_import()
install_phone_calls_stub()

import utils.twilio_service as twilio_service


def _fake_client_with(sid: str):
    client = MagicMock()
    client.messages.create.return_value = MagicMock(sid=sid)
    client.calls.create.return_value = MagicMock(sid=sid)
    return client


def test_send_sms_uses_from_number_and_returns_sid():
    with patch.object(twilio_service, '_get_client', return_value=_fake_client_with('SM123')):
        sid = twilio_service.send_sms('+14155552671', 'hello')
    assert sid == 'SM123'


def test_send_whatsapp_prefixes_whatsapp():
    client = _fake_client_with('WA1')
    with patch.object(twilio_service, '_get_client', return_value=client):
        sid = twilio_service.send_whatsapp('+14155552671', 'hi')
    assert sid == 'WA1'
    _, kwargs = client.messages.create.call_args
    assert kwargs['to'].startswith('whatsapp:')
    assert kwargs['from_'].startswith('whatsapp:')


def test_start_tts_call_returns_sid():
    with patch.object(twilio_service, '_get_client', return_value=_fake_client_with('CA9')):
        sid = twilio_service.start_tts_call('+14155552671', 'this is a test')
    assert sid == 'CA9'


def test_send_sms_requires_from_number():
    with patch.object(twilio_service, 'from_number', None):
        with pytest.raises(ValueError):
            twilio_service.send_sms('+14155552671', 'hello')
