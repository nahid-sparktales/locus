"""Provider-neutral presentation documents, with a complete Markdown fallback.

Only this boundary resolves filesystem metadata. Model descriptions remain prose;
counts, sizes and containment are never accepted as evidence from tool arguments.
"""
from __future__ import annotations

import json
import os
import re
import stat
from itertools import islice
from pathlib import Path
from typing import Any
from urllib.parse import quote, urlencode, urlsplit

from .capabilities import enabled as capability_enabled
from .image_files import image_info

MAX_PARTS = 40
MAX_ENTRIES = 500
MAX_DOCUMENT_BYTES = 1_000_000
#: Workspace pictures an ``image`` part may point at; format is re-derived
#: from the bytes, so a mislabelled file is rejected rather than trusted.
IMAGE_SUFFIXES = frozenset({'.png', '.jpg', '.jpeg', '.gif', '.webp'})
MAX_IMAGE_BYTES = 50_000_000
MAX_ALT_CHARS = 400
MAX_PROMPT_CHARS = 4_000
#: An ``interactive`` part is a body fragment rendered in a sealed web view.
#: The cap keeps the whole document under the 1 MB limit with room for prose.
MAX_INTERACTIVE_HTML_BYTES = 262_144
INTERACTIVE_HEIGHT = (160, 360, 720)
INTERACTIVE_DEFAULT_TITLE = 'Interactive explanation'
#: The variables the sealed host injects (``LocusTheme.cssVariableNames`` in
#: Locus/Theme+CSS.swift); the schema names them so the model can use them.
INTERACTIVE_CSS_VARIABLES = (
    '--locus-ink', '--locus-ink-soft', '--locus-paper', '--locus-paper-deep', '--locus-panel',
    '--locus-line', '--locus-muted', '--locus-accent', '--locus-danger', '--locus-success',
    '--locus-warning', '--locus-font', '--locus-mono',
)
#: Tags that would turn a fragment into a document, change its base, or pull
#: in another document. ``<meta`` is deliberately not here: inline SVG
#: carries ``<metadata>``. ``http-equiv`` is refused as a token because a meta
#: CSP after ours could only narrow, but a refresh redirect must never load.
_INTERACTIVE_FORBIDDEN = re.compile(
    r'<(?:!doctype|html|head|body|base|link|iframe|frame|object|embed|applet)[\s>/]|http-equiv',
    re.IGNORECASE,
)


class ResponsePartsError(ValueError):
    pass


def _text(value: Any, limit: int = 4_000) -> str:
    if not isinstance(value, str) or len(value) > limit:
        raise ResponsePartsError(f"expected text of at most {limit} characters")
    return value


def _optional(raw: dict, result: dict, *names: str) -> None:
    for name in names:
        if raw.get(name) is not None:
            result[name] = _text(raw[name])


def _file(raw: dict, workspace: str) -> dict:
    root = Path(workspace).resolve()
    path = Path(_text(raw.get('path'), 4096)).expanduser()
    lexical = Path(os.path.abspath(root / path))
    target = lexical.resolve()
    try:
        target.relative_to(root)
        relative = lexical.relative_to(root)
    except ValueError as exc:
        raise ResponsePartsError('output references must stay inside the current workspace') from exc
    is_link = lexical.is_symlink()
    result = {'path': str(relative), 'name': lexical.name, 'exists': lexical.exists() or is_link}
    if is_link:
        result['kind'] = 'symlink'
    elif lexical.exists():
        result['kind'] = 'directory' if lexical.is_dir() else 'file'
        if lexical.is_file():
            result['size'] = lexical.stat().st_size
    _optional(raw, result, 'description')
    return result


def _is_hidden(path: Path) -> bool:
    if path.name.startswith('.'):
        return True
    try:
        return bool(getattr(path.lstat(), 'st_flags', 0) & getattr(stat, 'UF_HIDDEN', 0))
    except OSError:
        return False


def normalize_parts(raw_parts: Any, workspace: str, *, allow_workspace: bool = True) -> list[dict]:
    if not isinstance(raw_parts, list) or not raw_parts or len(raw_parts) > MAX_PARTS:
        raise ResponsePartsError(f'parts must contain 1–{MAX_PARTS} objects')
    if len(json.dumps(raw_parts, ensure_ascii=False).encode()) > MAX_DOCUMENT_BYTES:
        raise ResponsePartsError('response document exceeds 1 MB')
    parts = []
    ids = set()
    for raw in raw_parts:
        if not isinstance(raw, dict):
            raise ResponsePartsError('each part must be an object')
        kind = raw.get('type')
        ident = _text(raw.get('id'), 128).strip()
        if not ident or ident in ids or ident == '__prose__':
            raise ResponsePartsError('part ids must be nonempty, unique and not __prose__')
        ids.add(ident)
        part = {'type': kind, 'id': ident}
        _optional(raw, part, 'title')
        if kind == 'markdown':
            part['text'] = _text(raw.get('text'), MAX_DOCUMENT_BYTES)
        elif kind == 'writing':
            variant = raw.get('variant', 'standard')
            if variant not in {'email', 'chat', 'document', 'standard', 'chat_message', 'social_post'}:
                raise ResponsePartsError('unsupported writing variant')
            part.update(variant=variant, body=_text(raw.get('body'), MAX_DOCUMENT_BYTES))
            _optional(raw, part, 'subject')
        elif kind in {'file_collection', 'artifact', 'image'}:
            if not allow_workspace:
                raise ResponsePartsError('workspace references are unavailable in this mode')
            # A supplied workspace cannot change the active task's authority.
            if raw.get('workspace') and Path(_text(raw['workspace'], 4096)).resolve() != Path(workspace).resolve():
                raise ResponsePartsError('workspace does not match the active task')
            part['workspace'] = str(Path(workspace).resolve())
            if kind == 'artifact':
                verified = _file(raw, workspace)
                part.update({key: value for key, value in verified.items() if key in {'path', 'description'}})
            elif kind == 'image':
                part.update(_image(raw, workspace))
            else:
                entries = raw.get('entries')
                if not isinstance(entries, list) or len(entries) > MAX_ENTRIES or not all(isinstance(e, dict) for e in entries):
                    raise ResponsePartsError(f'file entries must contain at most {MAX_ENTRIES} objects')
                for flag in ('collapsed', 'show_hidden'):
                    if raw.get(flag) is not None and not isinstance(raw[flag], bool):
                        raise ResponsePartsError(f'{flag} must be a Boolean')
                    part[flag] = raw.get(flag) or False
                part['entries'] = [_file(e, workspace) for e in entries]
                root = Path(workspace).resolve()
                resolved = [(root / e['path']).resolve() for e in part['entries']]
                if len(set(resolved)) != len(resolved):
                    raise ResponsePartsError('file entries must not repeat a resolved path')
                # Selection completeness is unverified unless runtime independently
                # compares this exact set against a supplied directory.
                part['complete'] = False
                directory = raw.get('directory')
                if directory is not None:
                    directory_ref = _file({'path': directory}, workspace)
                    base = Path(workspace).resolve() / directory_ref['path']
                    if not base.is_dir():
                        raise ResponsePartsError('collection directory is not a directory')
                    visible = (entry for entry in base.iterdir() if part['show_hidden'] or not _is_hidden(entry))
                    observed = list(islice(visible, MAX_ENTRIES + 1))
                    if len(observed) <= MAX_ENTRIES:
                        expected = {str(entry.relative_to(root)) for entry in observed}
                        selected = {e['path'] for e in part['entries']}
                        part['total_count'] = len(observed)
                        part['complete'] = selected == expected
        elif kind == 'sources':
            refs = raw.get('references')
            if not isinstance(refs, list) or len(refs) > MAX_ENTRIES:
                raise ResponsePartsError('invalid source references')
            part['references'] = []
            for index, ref in enumerate(refs):
                if not isinstance(ref, dict):
                    raise ResponsePartsError('source must be an object')
                source = {'id': _text(ref.get('id', f'source-{index}'), 128)}
                _optional(ref, source, 'title')
                if ref.get('url'):
                    url = _text(ref['url'], 8192)
                    parsed = urlsplit(url)
                    if parsed.scheme not in {'https', 'http'} or not parsed.hostname or parsed.username or parsed.password:
                        raise ResponsePartsError('sources require an ordinary HTTP(S) URL')
                    source['url'] = url
                elif isinstance(ref.get('document'), dict):
                    if not allow_workspace:
                        raise ResponsePartsError('document sources are unavailable in this mode')
                    doc = ref['document']
                    if doc.get('workspace') and Path(_text(doc['workspace'], 4096)).resolve() != Path(workspace).resolve():
                        raise ResponsePartsError('document workspace does not match the active task')
                    verified = _file(doc, workspace)
                    document = {'workspace': str(Path(workspace).resolve()), 'path': verified['path']}
                    _optional(doc, document, 'content_hash')
                    if doc.get('location') is not None:
                        if not isinstance(doc['location'], dict) or len(json.dumps(doc['location'])) > 8000:
                            raise ResponsePartsError('invalid document location')
                        document['location'] = doc['location']
                    source['document'] = document
                else:
                    raise ResponsePartsError('source needs a URL or document reference')
                part['references'].append(source)
        elif kind == 'interactive':
            part.update(_interactive(raw, part.get('title')))
        else:
            raise ResponsePartsError('unsupported response part type')
        parts.append(part)
    return parts


def _image(raw: dict, workspace: str) -> dict:
    """An image part's verified fields: dimensions and format come from the file."""
    if not capability_enabled('image_generation_v1'):
        raise ResponsePartsError('image parts are disabled in this build')
    verified = _file(raw, workspace)
    if verified.get('kind') != 'file':
        raise ResponsePartsError('image must be an existing file inside the workspace')
    if Path(verified['path']).suffix.lower() not in IMAGE_SUFFIXES:
        raise ResponsePartsError('image must be a PNG, JPEG, GIF or WebP file')
    if int(verified.get('size') or 0) > MAX_IMAGE_BYTES:
        raise ResponsePartsError('image exceeds 50 MB')
    info = image_info(Path(workspace).resolve() / verified['path'], MAX_IMAGE_BYTES)
    if info is None:
        raise ResponsePartsError('image file is not a readable PNG, JPEG, GIF or WebP')
    result = {'path': verified['path'], 'width': info.width, 'height': info.height,
              'format': info.format, 'size': verified['size']}
    alt = raw.get('alt')
    if alt is not None:
        alt = _text(alt, MAX_ALT_CHARS).strip()
    # A derived alt is truncated rather than refused: a long title is a valid
    # title, and the cap is a property of the alt text, whatever its source.
    title = raw.get('title')
    derived = _text(title).strip()[:MAX_ALT_CHARS].rstrip() if title is not None else ''
    result['alt'] = alt or derived or verified['name']
    if raw.get('prompt') is not None:
        result['prompt'] = _text(raw['prompt'], MAX_PROMPT_CHARS)
    if raw.get('source_path') is not None:
        source = _file({'path': raw['source_path']}, workspace)
        if source.get('kind') != 'file':
            raise ResponsePartsError('image source_path must be an existing file inside the workspace')
        result['source_path'] = source['path']
    return result


def _interactive(raw: dict, title: str | None) -> dict:
    """An interactive part: a bounded body fragment plus its universal text fallback."""
    if not capability_enabled('interactive_answers_v1'):
        raise ResponsePartsError('interactive parts are disabled in this build')
    label = (title if title is not None else INTERACTIVE_DEFAULT_TITLE).strip()
    if not label or len(label) > 200:
        raise ResponsePartsError('interactive title must be 1–200 characters')
    summary = _text(raw.get('summary'), MAX_PROMPT_CHARS).strip()
    if not summary:
        raise ResponsePartsError('interactive parts require a plain-language summary')
    html = raw.get('html')
    if not isinstance(html, str) or not html.strip():
        raise ResponsePartsError('interactive parts require an html body fragment')
    if len(html.encode('utf-8')) > MAX_INTERACTIVE_HTML_BYTES:
        raise ResponsePartsError('interactive html exceeds 256 KB')
    if _INTERACTIVE_FORBIDDEN.search(html):
        raise ResponsePartsError('interactive html must be a body fragment without document, base, link, frame or object tags')
    minimum, default, maximum = INTERACTIVE_HEIGHT
    height = raw.get('height')
    if height is None:
        height = default
    if isinstance(height, float) and height.is_integer():
        height = int(height)
    if isinstance(height, bool) or not isinstance(height, int) or not minimum <= height <= maximum:
        raise ResponsePartsError(f'interactive height must be an integer between {minimum} and {maximum}')
    return {'title': label, 'summary': summary, 'html': html, 'height': height}


def _link(label: str, path: str) -> str:
    return '[' + label.replace('\\', '\\\\').replace('[', '\\[').replace(']', '\\]') + '](' + path.replace('(', '%28').replace(')', '%29').replace(' ', '%20').replace('\n', '%0A') + ')'


def markdown_fallback(document: dict) -> str:
    output = []
    for part in document.get('parts', []):
        kind = part.get('type')
        heading = part.get('title')
        lines = [f'### {heading}'] if heading else []
        if kind == 'markdown':
            lines.append(part.get('text', ''))
        elif kind == 'writing':
            if part.get('subject'):
                lines.append('Subject: ' + part['subject'])
            lines.append(part['body'])
        elif kind == 'file_collection':
            for entry in part['entries']:
                label = entry.get('name') or entry['path']
                link = _link(label, quote(str(Path(part['workspace']) / entry['path']), safe='/'))
                lines.append('- ' + link + (' — ' + entry['description'] if entry.get('description') else ''))
            if not part.get('entries'):
                lines.append('No files in this collection.')
            if not part.get('complete'):
                lines.append('Selected files; this may not be the complete directory.')
        elif kind == 'artifact':
            lines.append(_link(part.get('title') or Path(part['path']).name,
                               quote(str(Path(part['workspace']) / part['path']), safe='/')))
            if part.get('description'):
                lines.append(part['description'])
        elif kind == 'image':
            # The picture itself is the heading: older clients render the
            # absolute in-workspace link inline, so the fallback is never empty.
            lines = ['!' + _link(part.get('alt') or Path(part['path']).name,
                                 quote(str(Path(part['workspace']) / part['path']), safe='/'))]
            caption = part.get('title') or part.get('prompt') or f"Image saved to {part['path']}"
            if part.get('source_path'):
                caption += f" — edited from {part['source_path']}"
            lines.append(caption)
        elif kind == 'interactive':
            lines.append(part['summary'])
            lines.append('Interactive version available in Locus for Mac.')
        elif kind == 'sources':
            for source in part['references']:
                if source.get('url'):
                    url = source['url']
                    label = source.get('title') or url
                else:
                    doc = source['document']
                    query = {'workspace': doc['workspace']}
                    if doc.get('content_hash'):
                        query['hash'] = doc['content_hash']
                    if doc.get('location'):
                        query['locator'] = json.dumps(doc['location'], separators=(',', ':'))
                    url = 'locus-workspace://open/' + quote(doc['path'], safe='/') + '?' + urlencode(query)
                    label = source.get('title') or doc['path']
                lines.append('- ' + _link(label, url))
        output.append('\n\n'.join(lines) if kind != 'file_collection' else '\n'.join(lines))
    return '\n\n'.join(text for text in output if text.strip())


def merge_staged(existing: dict[str, dict], parts: list[dict]) -> dict[str, dict]:
    """``existing`` with ``parts`` staged over it, re-checked against the document limits.

    A repeated id replaces the earlier part in place; a new id is appended. The
    input mapping is never mutated, so a rejected merge leaves prior staging intact.
    """
    updated = {**existing, **{part['id']: part for part in parts}}
    if len(updated) > MAX_PARTS or len(json.dumps(updated, ensure_ascii=False).encode()) > MAX_DOCUMENT_BYTES:
        raise ResponsePartsError('staged output exceeds the response document limit')
    return updated


def response_document(prose: str, parts: list[dict]) -> dict:
    result = list(parts)
    if prose.strip():
        result.insert(0, {'type': 'markdown', 'id': '__prose__', 'text': prose})
    return {'version': 1, 'parts': result}


ATTACH_OUTPUT_PARTS_SCHEMA = {
    'type': 'function', 'function': {
        'name': 'attach_output_parts',
        'description': (
            'Stage native file collections, reusable writing, artifacts, sources, workspace images or interactive explanations for the next final answer. '
            'IDs replace earlier staged parts. Do not repeat these contents in the final prose. File metadata is verified by the runtime; supply directory on a collection only for an exact nonrecursive directory listing. '
            'image: a workspace PNG/JPEG/WebP/GIF, e.g. a chart from your script; generate_image stages its own. '
            'interactive: html plus a required plain summary, for something a reader should manipulate.'
        ),
        'parameters': {'type': 'object', 'properties': {
            'parts': {'type': 'array', 'minItems': 1, 'maxItems': MAX_PARTS,
                      'items': {'type': 'object', 'properties': {
                          'id': {'type': 'string'}, 'type': {'type': 'string', 'enum': ['markdown', 'file_collection', 'writing', 'artifact', 'sources', 'image', 'interactive']},
                          'title': {'type': 'string'}, 'text': {'type': 'string'}, 'body': {'type': 'string'},
                          'variant': {'type': 'string'}, 'subject': {'type': 'string'}, 'path': {'type': 'string'},
                          'workspace': {'type': 'string'}, 'description': {'type': 'string'}, 'directory': {'type': 'string'},
                          'collapsed': {'type': 'boolean'}, 'show_hidden': {'type': 'boolean'},
                          'alt': {'type': 'string'}, 'prompt': {'type': 'string'}, 'source_path': {'type': 'string'},
                          'summary': {'type': 'string'}, 'height': {'type': 'integer'},
                          'html': {'type': 'string', 'description': (
                              'Self-contained body fragment: inline style/script only, no network or external resources, '
                              'no document/base/link/iframe/object tags, max 256 KB. Style with the CSS variables '
                              + ', '.join(INTERACTIVE_CSS_VARIABLES)
                              + '; label every control and keep it keyboard-operable.')},
                          'entries': {'type': 'array', 'items': {'type': 'object', 'properties': {'path': {'type': 'string'}, 'description': {'type': 'string'}}, 'required': ['path']}},
                          'references': {'type': 'array', 'items': {'type': 'object', 'properties': {'id': {'type': 'string'}, 'title': {'type': 'string'}, 'url': {'type': 'string'}, 'document': {'type': 'object'}}, 'required': ['id']}},
                      }, 'required': ['id', 'type']}},
        }, 'required': ['parts']},
    },
}
