"""Dated API estimate provenance; unmatched routes remain unpriced.

Source checked 2026-09-09:
https://platform.claude.com/docs/en/build-with-claude/prompt-caching
These are ordinary USD API estimates, excluding discounts and account overrides.
"""
from urllib.parse import urlsplit

ANTHROPIC_BASE_RATES = {
    'claude-sonnet-4-6': (3, 15),
    'claude-sonnet-4-5': (3, 15),
    'claude-haiku-4-5': (1, 5),
    'claude-opus-4-6': (5, 25),
    'claude-opus-4-5': (5, 25),
    'claude-opus-4-7': (5, 25),
    'claude-opus-4-8': (5, 25),
}


def estimate_rates(model, client, configured=None):
    if configured:
        return dict(configured)
    if getattr(client, 'auth_style', '') != 'anthropic' or urlsplit(getattr(client, 'base_url', '')).hostname != 'api.anthropic.com':
        return {}
    rates = next((value for key, value in ANTHROPIC_BASE_RATES.items() if model == key or model.startswith(key + '-20')), None)
    if not rates:
        return {}
    ordinary, output = rates
    return {'input_tokens': ordinary, 'output_tokens': output, 'cache_read_input_tokens': ordinary * .1,
            'cache_creation_5m_input_tokens': ordinary * 1.25, 'cache_creation_1h_input_tokens': ordinary * 2,
            'source': 'https://platform.claude.com/docs/en/build-with-claude/prompt-caching',
            'as_of': '2026-09-09', 'basis': 'ordinary API estimate; account discounts and modifiers excluded'}
