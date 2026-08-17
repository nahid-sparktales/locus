#!/bin/zsh

set -eu

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

failed=0

report_matches() {
    local title="$1"
    local matches="$2"
    if [[ -n "$matches" ]]; then
        print -u2 "error: $title"
        print -u2 -- "$matches"
        failed=1
    fi
}

report_matches \
    "Use LocusType or Font.locus instead of direct point-sized SwiftUI fonts." \
    "$(rg -n '\.font\(\.system\(size:|Font\.system\(size:' Locus --glob '*.swift' --glob '!Theme.swift' || true)"

report_matches \
    "AppKit prose fonts must be at least 11 points." \
    "$(rg -n -P 'NSFont\.(?:systemFont|monospacedSystemFont)\(ofSize: (?:[0-9](?:\.[0-9]+)?|10(?:\.0+)?)\b' Locus --glob '*.swift' || true)"

report_matches \
    "Use a shared Locus button style instead of plain or borderless styling." \
    "$(rg -n '\.buttonStyle\(\.(?:plain|borderless)\)' Locus --glob '*.swift' || true)"

report_matches \
    "Route custom animations through LocusMotion." \
    "$(rg -n -P '(?:withAnimation|\.animation)\((?![^\n]*LocusMotion)' Locus --glob '*.swift' --glob '!Theme.swift' || true)"

report_matches \
    "Route spatial transitions through LocusMotion.transition." \
    "$(rg -n '\.transition\(\.move' Locus --glob '*.swift' || true)"

report_matches \
    "Repeating animation belongs only in the central motion policy." \
    "$(rg -n 'repeatForever' Locus --glob '*.swift' --glob '!Theme.swift' || true)"

if (( failed )); then
    exit 1
fi

print "Design-system audit passed."
