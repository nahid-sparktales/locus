---
name: last30days
description: "Research a topic across social platforms and the web over the last 30 days using the bundled Last 30 Days research engine."
---

# Last 30 Days for Locus

Read `UPSTREAM_SKILL.md` before running the research engine. Its scripts and references are bundled in this directory. Use this directory as `SKILL_DIR` for every upstream command; do not search other installations or update the pinned app copy.

Check Python 3 and Node.js availability when invoked. Run `python3 "<absolute skill root>/scripts/last30days.py" --help` for the bundled engine's options and use its doctor mode to identify available sources. Use only configured credentials and report sources that are unavailable. The skill being bundled does not imply that paid APIs, browser sessions, or external tools are configured.

Map upstream Bash, Read, Write, AskUserQuestion, and WebSearch to available Locus execution, file, user-input, and web tools. Write research artifacts to the workspace; keep bundled scripts read-only. Upstream self-update, scheduler, publishing, or account-setup instructions apply only when requested by the user. No hooks or background jobs are installed by loading this skill.

