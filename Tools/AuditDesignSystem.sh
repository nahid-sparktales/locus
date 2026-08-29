#!/bin/zsh

# Design-system source audit.
#
# Each rule greps for a pattern the design system forbids and compares the
# number of hits against a checked-in baseline. Anything above the baseline
# fails; anything at or below it passes. That makes the audit a ratchet: the
# violations already in the tree are tolerated while new ones are blocked, so
# the check can be honest today rather than after a burn-down.
#
# Run with --update-baseline after removing violations to lock in the lower
# number. Lowering a baseline is the only way it changes; nothing raises it
# automatically.

set -eu

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

update_baseline=0
for arg in "$@"; do
    case "$arg" in
        --update-baseline) update_baseline=1 ;;
        *)
            print -u2 "usage: ${0:t} [--update-baseline]"
            exit 2
            ;;
    esac
done

# A check whose pass condition is "found nothing" has to prove its finder ran.
# Without this, every rule below returned no matches and the audit reported
# success on any machine without ripgrep — which is what CI did from the day
# this script was added until the day this guard arrived.
if ! command -v rg > /dev/null 2>&1; then
    print -u2 "error: ${0:t} requires ripgrep; install it with 'brew install ripgrep'"
    exit 2
fi

baseline_file="$repo_root/Tools/design-system-baseline.txt"

typeset -A baseline
if [[ -f "$baseline_file" ]]; then
    while IFS=' ' read -r key value; do
        [[ -z "$key" || "$key" == \#* ]] && continue
        baseline[$key]="$value"
    done < "$baseline_file"
fi

typeset -A observed
typeset -a rule_order
failed=0

report_matches() {
    local key="$1"
    local title="$2"
    local matches="$3"
    local -i count=0
    if [[ -n "$matches" ]]; then
        local -a lines=("${(@f)matches}")
        count=${#lines}
    fi
    observed[$key]=$count
    rule_order+=("$key")
    (( update_baseline )) && return 0

    local -i allowed=${baseline[$key]:-0}
    if (( count > allowed )); then
        print -u2 "error: $title"
        print -u2 -- "  baseline allows $allowed, found $count"
        print -u2 -- "$matches"
        failed=1
    elif (( count < allowed )); then
        print "$title"
        print -- "  improved: $count, baseline $allowed — rerun with --update-baseline to lock it in"
    fi
    return 0
}

report_matches swiftui-point-fonts \
    "Use LocusType or Font.locus instead of direct point-sized SwiftUI fonts." \
    "$(rg -n '\.font\(\.system\(size:|Font\.system\(size:' Locus --glob '*.swift' --glob '!Theme.swift' || true)"

report_matches appkit-small-fonts \
    "AppKit prose fonts must be at least 11 points." \
    "$(rg -n -P 'NSFont\.(?:systemFont|monospacedSystemFont)\(ofSize: (?:[0-9](?:\.[0-9]+)?|10(?:\.0+)?)\b' Locus --glob '*.swift' || true)"

report_matches plain-button-styles \
    "Use a shared Locus button style instead of plain or borderless styling." \
    "$(rg -n '\.buttonStyle\(\.(?:plain|borderless)\)' Locus --glob '*.swift' || true)"

report_matches custom-animations \
    "Route custom animations through LocusMotion." \
    "$(rg -n -P '(?:withAnimation|\.animation)\((?![^\n]*LocusMotion)' Locus --glob '*.swift' --glob '!Theme.swift' || true)"

report_matches move-transitions \
    "Route spatial transitions through LocusMotion.transition." \
    "$(rg -n '\.transition\(\.move' Locus --glob '*.swift' || true)"

report_matches repeat-forever \
    "Repeating animation belongs only in the central motion policy." \
    "$(rg -n 'repeatForever' Locus --glob '*.swift' --glob '!Theme.swift' || true)"

if (( update_baseline )); then
    {
        print -- "# Design-system audit baseline: the number of existing violations"
        print -- "# each rule is allowed. New violations fail CI; removing them and"
        print -- "# rerunning Tools/AuditDesignSystem.sh --update-baseline lowers these."
        for key in $rule_order; do
            print -- "$key ${observed[$key]}"
        done
    } > "$baseline_file"
    print "Baseline written to ${baseline_file:t}."
    exit 0
fi

if (( failed )); then
    print -u2 "Design-system audit failed: a rule has more violations than its baseline allows."
    exit 1
fi

print "Design-system audit passed."
