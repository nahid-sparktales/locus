#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
web_root="${repo_root}/WalletConnectionsWeb"

cd "${web_root}"
npm ci --ignore-scripts --no-audit --no-fund
npm run build
