> For the complete documentation index, see [llms.txt](https://locus-3.gitbook.io/locus-docs/llms.txt). Markdown versions of documentation pages are available by appending `.md` to page URLs; this page is available as [Markdown](https://locus-3.gitbook.io/locus-docs/models-and-accounts/hosted-and-custom-models.md).

# Hosted & Custom Models

Add a ChatGPT plan, OpenAI API, Claude, Kimi, or compatible custom endpoint.

Add accounts under Settings → Models & Providers.

## ChatGPT-plan access

Choose **ChatGPT**, install the optional Codex component if prompted, and complete OpenAI's managed browser sign-in. Locus discovers the plan's visible models and usage windows. This route does not use or fall back to an OpenAI API key.

Each account has a **Codex-native mode** toggle:

* New ChatGPT accounts begin with the Locus contract—Locus's prompt and tools, approved memory, cross-chat context, and skill index.
* Existing accounts keep the setting they had before the 2.1 update.
* Turn Codex-native mode on for the model's Codex prompt, voice, and Codex-shaped shell, patch, and plan tools. Locus still owns execution, permission prompts, deny lists, and edit previews.
* Codex-native chats deliberately omit approved memory, cross-chat context, and the skill index.
* Changing the toggle restarts that conversation's server-side context. The first message in an existing ChatGPT chat after the update may replay its history once.

The account editor also controls model-supported reasoning effort and optional OpenAI web search. Reasoning effort applies on the next turn without resetting the conversation; higher effort can use plan quota faster. Web search is off by default and sends search queries to OpenAI when enabled.

Just Chat, explicit teams, evaluations, and non-ChatGPT providers keep their existing behavior.

## API-backed accounts

| Account    | Endpoint               | Authentication             |
| ---------- | ---------------------- | -------------------------- |
| OpenAI API | api.openai.com/v1      | OpenAI API key             |
| Claude     | api.anthropic.com/v1   | Anthropic API key          |
| Kimi       | api.moonshot.ai/v1     | Moonshot API key           |
| Kimi Code  | api.kimi.com/coding/v1 | Kimi Code subscription key |
| Custom     | Your URL               | Endpoint key if required   |

Use **Test Connection** before selecting the route. Locus reports a rejected key, an incorrect URL, or a waking endpoint. When a provider has no model-list route, the test sends a minimal completion.

Multiple accounts for one provider remain distinct. Model and account changes requested during a run wait until it finishes. Removing the active hosted account returns the session to local Ollama. In 2.1, switching models no longer checks hosted ChatGPT or Kimi models against the locally installed Ollama list.

## Custom endpoints and safety

Custom accounts support vLLM, TGI, llama.cpp, Hugging Face endpoints, and compatible services. Authenticated non-loopback endpoints must use HTTPS. Redirects are refused so credentials cannot follow a response to another origin.

If the endpoint rejects tool calling, Locus retries once without tools and says the route can answer but cannot edit. If it rejects an image, Locus retries once without images and keeps that route text-only for the session.

{% hint style="warning" %}
Selecting a hosted route sends the prompt and included project context to that provider. Automatic hosted team routing requires separate one-time consent.
{% endhint %}
