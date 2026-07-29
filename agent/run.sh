#!/usr/bin/env bash
# Run ollama-code from the repo checkout, keeping your current directory.
set -e
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
export PYTHONPATH="$DIR${PYTHONPATH:+:$PYTHONPATH}"
exec "$DIR/.venv/bin/python" -m ollama_code "$@"
