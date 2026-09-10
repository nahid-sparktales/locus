# OpenAI image models verification

Base: `09604425494d02f962824e4932886d1b10291430`.
Implementation branch: `codex/account-navigation-fixes`.

## Scope

The API image picker now includes GPT Image 2.5 Sunburst, GPT Image 2.5
Flare, and GPT Image 1.5 alongside the existing models. New settings default
to Sunburst; explicit saved choices survive decoding and relaunch. Sunburst
and Flare offer Extra High and Max quality. GPT Image 2 and 2.5 offer 2K/4K
presets and validated custom dimensions.

Generation and multipart editing use the selected model, size, and quality,
including dated snapshots. Unsupported options are refused before a
provider request, output write, or image allowance is consumed. Rejected
provider updates preserve the previous configuration. Switching models in
Settings retains compatible options and resets only unsupported ones.

The managed ChatGPT account remains on the bundled runtime's GPT Image 2.
No API fallback, credential changes, extra permissions, evaluation, or cost
accounting are introduced. The changes use existing settings and request
fields; no database or mobile wire migration is needed.

## Deterministic validation

- Full backend suite: **2,347 passed** in 285.19 seconds.
- Image backend suite: **55 passed**, including provider-route-to-tool
  generation/editing for both 2.5 aliases and snapshots, permission preview
  attribution, custom-size boundaries, invalid option refusals, and legacy
  model preservation.
- Native image settings suite: **32 passed**, including settings round-trip
  through the actual provider handoff, model-family changes, and invalid
  custom dimensions retaining the previous saved size.
- macOS UI: **2 passed**. The new-model scenario selects Flare and Max,
  enters custom dimensions, switches to GPT Image 2 (retaining dimensions
  and resetting quality), then GPT Image 1.5 (resetting dimensions and
  removing unsupported controls). The managed ChatGPT scenario confirms
  the GPT Image 2 view hides the API model/options controls.
- Python lint, protocol manifest (revision 2), generated Xcode project,
  design-system audit, and whitespace checks passed.

Native/UI tests ran on macOS 26.4.1 with Xcode 26.6 using an isolated bundle
identifier. The API UI fixture uses an in-memory credential store and an
invalid example host; it never generates an image or uses production state.
An initial backend run exposed an error-message compatibility regression;
the existing quoted argument names were restored before the passing rerun.

Raw logs and both Xcode result bundles are retained locally at
`/Users/nahid/Documents/locus-openai-image-models-validation`.

## Live coverage and release gate

OpenAI's model and image-generation documentation was checked on September
10, 2026; links and request constraints are recorded in
[the implementation notes](../LocusImageAndInteractiveAnswersImplementation.md).
No live image request, provider recovery campaign, or benchmark was run.
Stubbed requests establish deterministic behavior, not live model access or
image quality. Hosted CI remains a separate gate before a release.
