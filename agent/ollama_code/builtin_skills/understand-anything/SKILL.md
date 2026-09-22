---
name: understand-anything
description: "Analyze and explore a codebase with Understand Anything: interactive knowledge graphs, architecture explanations, onboarding, change analysis, and graph chat."
---

# Understand Anything for Locus

Read the upstream mode that matches the request:

- `understand`: Analyze a codebase to produce an interactive knowledge graph for understanding architecture, components, and relationships — `upstream/skills/understand/SKILL.md`
- `understand-chat`: Use when you need to ask questions about a codebase or understand code using a knowledge graph — `upstream/skills/understand-chat/SKILL.md`
- `understand-dashboard`: Launch the interactive web dashboard to visualize a codebase's knowledge graph — `upstream/skills/understand-dashboard/SKILL.md`
- `understand-diff`: Use when you need to analyze git diffs or pull requests to understand what changed, affected components, and risks — `upstream/skills/understand-diff/SKILL.md`
- `understand-domain`: Extract business domain knowledge from a codebase and generate an interactive domain flow graph. Works standalone (lightweight scan) or derives from an existing /understand knowledge graph. — `upstream/skills/understand-domain/SKILL.md`
- `understand-explain`: Use when you need a deep-dive explanation of a specific file, function, or module in the codebase — `upstream/skills/understand-explain/SKILL.md`
- `understand-figma`: Analyze a Figma file via the Figma REST API and generate an interactive design knowledge graph (pages, screens, components, component sets, instances, design tokens) with a kind:"design" dashboard. — `upstream/skills/understand-figma/SKILL.md`
- `understand-knowledge`: Analyze a Karpathy-pattern LLM wiki knowledge base and generate an interactive knowledge graph with entity extraction, implicit relationships, and topic clustering. — `upstream/skills/understand-knowledge/SKILL.md`
- `understand-onboard`: Use when you need to generate an onboarding guide for new team members joining a project — `upstream/skills/understand-onboard/SKILL.md`

Use `understand` for the initial graph and `understand-dashboard` to explore it. Read only the selected mode and its referenced agents/resources.

## Runtime and paths

The complete plugin source is bundled under `upstream/`, including its Node packages and lockfile. Node.js >=22 and pnpm >=10 are external prerequisites; check them when this skill is invoked. The app bundle is read-only. Copy `upstream/` to a writable task-local directory such as `.locus/understand-anything/6df3065f1d8d/` before installing dependencies or building it. Set `CLAUDE_PLUGIN_ROOT` to that absolute copied directory for upstream commands. This environment variable supplies a source path; it does not require Claude Code. Read the copied `skills/<mode>/SKILL.md` and resolve all plugin-relative files there.

Set `UNDERSTAND_NO_WORKTREE_REDIRECT=1` so results stay in the user's selected workspace. Use the bundled lockfile (`pnpm install --frozen-lockfile`), then the build command in the selected mode. Report missing dependencies or failed builds accurately. Do not write into Locus's bundled source or silently switch to an unrelated installed plugin.

Map upstream Read/Write/Bash and agent steps to available Locus file, execution, and team tools. Perform analysis sequentially when delegation is unavailable. Do not register the bundled hooks or enable auto-update unless the user requests them. Keep graph files under the selected project's `.ua/` (or its existing `.understand-anything/`), as described upstream.

