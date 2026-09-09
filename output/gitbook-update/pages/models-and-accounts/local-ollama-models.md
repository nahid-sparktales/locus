# Local Ollama Models

Run Locus locally with Ollama, manage model files, and understand practical context windows.

## Choose or install a model

Pick an installed model from the header. The model library can browse compatible GGUF files on Hugging Face, compare quantizations and sizes, download through Ollama with progress and cancellation, and activate the result.

Local models report vision support from Ollama's capability list. Locus warns before sending images to a model known not to accept them.

From the model library you can remove a model from Locus without touching its files or delete the local model when its provider supports removal.

## Context windows

Locus budgets against the window the model actually runs with, not only the maximum printed on its model card. It reads the resident Ollama runner, remembers the observed value by host and model, and marks unknown values honestly.

In current V2 settings, leaving the local context field empty lets Locus request the model's trained ceiling up to 32,768 tokens. You can pin an exact `num_ctx` value when memory use requires it. Larger windows increase KV-cache memory; Locus can back off a model that would otherwise spill heavily onto the CPU.

The context meter reserves room for the system prompt, tools, and reply. Automatic compaction uses the practical window.

## Ollama on another machine

Configure the Ollama host in Settings → Models & Providers. A remote Ollama server must listen beyond loopback and be reachable through the selected network route. Locus treats its configured Ollama host as direct traffic so a broken external proxy cannot cut the app off from its model runtime.
