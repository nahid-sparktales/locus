"""Batch, streaming and interrupted local answers share one literal-safe scanner."""
import pytest

from ollama_code.render import ThinkFilter, strip_think


@pytest.mark.parametrize('literal', [
    'Use `<think>literal</think>` here.',
    'Use ``a`<thinking>literal</thinking>`` here.',
    '\\<think>literal</think> and \\<thinking>literal</thinking>',
    '```xml\n<think>literal</think>\n```\n',
    '  ~~~~xml\n<thinking>literal</thinking>\n  ~~~~\n',
    '````xml\n```\n<think>literal</think>\n````\n',
    '```xml\n``` invalid closing fence\n<think>literal</think>\n```\n',
    '    <think>literal</think>\n',
    '\t<thinking>literal</thinking>\n',
])
def test_literal_tags_survive_every_single_split_and_character_stream(literal):
    source = '<think>private</think>' + literal + '\n<thinking>more private</thinking>Done.'
    expected = literal + '\nDone.'
    for chunks in ([source[:split], source[split:]] for split in range(len(source) + 1)):
        scanner = ThinkFilter()
        assert ''.join(scanner.feed(chunk) for chunk in chunks) + scanner.flush() == expected
        assert scanner.thinking == 'privatemore private'
    scanner = ThinkFilter()
    assert ''.join(scanner.feed(char) for char in source) + scanner.flush() == expected
    assert strip_think(source) == expected.strip()


def test_unfinished_inline_code_conservatively_keeps_remaining_tags():
    source = 'Example `<think>literal</think>\n<think>still literal</think>'
    scanner = ThinkFilter()
    assert ''.join(scanner.feed(char) for char in source) + scanner.flush() == source
    assert scanner.thinking == ''


def test_escaped_backslash_does_not_escape_following_reasoning_tag():
    source = r'\\<think>private</think>visible'
    scanner = ThinkFilter()
    assert ''.join(scanner.feed(char) for char in source) + scanner.flush() == r'\\visible'
    assert scanner.thinking == 'private'


def test_interrupted_literal_tail_is_preserved_and_flush_is_idempotent():
    scanner = ThinkFilter()
    scanner.feed('`<thi')
    assert scanner.flush_all() == '`<thi'
    assert scanner.flush_all() == '`<thi'
    assert strip_think('Answer <think>private unfinished') == 'Answer'
