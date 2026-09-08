"""Provider-neutral presentation documents, with a complete Markdown fallback.

Only this boundary resolves filesystem metadata. Model descriptions remain prose;
counts, sizes and containment are never accepted as evidence from tool arguments.
"""
from __future__ import annotations

import json
import os
import stat
from itertools import islice
from pathlib import Path
from typing import Any
from urllib.parse import quote, urlencode, urlsplit

MAX_PARTS = 40
MAX_ENTRIES = 500
MAX_DOCUMENT_BYTES = 1_000_000


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
        elif kind in {'file_collection', 'artifact'}:
            if not allow_workspace:
                raise ResponsePartsError('workspace references are unavailable in this mode')
            # A supplied workspace cannot change the active task's authority.
            if raw.get('workspace') and Path(_text(raw['workspace'], 4096)).resolve() != Path(workspace).resolve():
                raise ResponsePartsError('workspace does not match the active task')
            part['workspace'] = str(Path(workspace).resolve())
            if kind == 'artifact':
                verified = _file(raw, workspace)
                part.update({key: value for key, value in verified.items() if key in {'path', 'description'}})
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
        else:
            raise ResponsePartsError('unsupported response part type')
        parts.append(part)
    return parts


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
        'description': 'Stage native file collections, reusable writing, artifacts or sources for the next final answer. IDs replace earlier staged parts. Do not repeat these contents in the final prose. File metadata is verified by the runtime; supply directory on a collection only for an exact nonrecursive directory listing.',
        'parameters': {'type': 'object', 'properties': {
            'parts': {'type': 'array', 'minItems': 1, 'maxItems': MAX_PARTS,
                      'items': {'type': 'object', 'properties': {
                          'id': {'type': 'string'}, 'type': {'type': 'string', 'enum': ['markdown', 'file_collection', 'writing', 'artifact', 'sources']},
                          'title': {'type': 'string'}, 'text': {'type': 'string'}, 'body': {'type': 'string'},
                          'variant': {'type': 'string'}, 'subject': {'type': 'string'}, 'path': {'type': 'string'},
                          'workspace': {'type': 'string'}, 'description': {'type': 'string'}, 'directory': {'type': 'string'},
                          'collapsed': {'type': 'boolean'}, 'show_hidden': {'type': 'boolean'},
                          'entries': {'type': 'array', 'items': {'type': 'object', 'properties': {'path': {'type': 'string'}, 'description': {'type': 'string'}}, 'required': ['path']}},
                          'references': {'type': 'array', 'items': {'type': 'object', 'properties': {'id': {'type': 'string'}, 'title': {'type': 'string'}, 'url': {'type': 'string'}, 'document': {'type': 'object'}}, 'required': ['id']}},
                      }, 'required': ['id', 'type']}},
        }, 'required': ['parts']},
    },
}
