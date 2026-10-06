# Contributing to Harbor

Keep file fixtures small and deterministic. Unit tests run with a temporary
profile so no command reads personal notes or changes a developer's settings.
Tests must not fetch models or send requests to a running host unless the test
explicitly supplies an isolated stub transport.

## Review

Include the triggering input, observed result, and expected result in a bug
report. Record timing measurements as diagnostics rather than hard performance
guarantees. Do not claim a mocked embedding proves semantic retrieval quality.
