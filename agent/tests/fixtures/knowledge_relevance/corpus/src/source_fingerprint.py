"""Bind a note to the file bytes that were actually inspected."""
import hashlib


def source_fingerprint(path):
    if not path.is_file():
        return None
    return hashlib.sha256(path.read_bytes()).hexdigest()


def sources_changed(saved_sources):
    return any(source_fingerprint(path) != digest for path, digest in saved_sources)
