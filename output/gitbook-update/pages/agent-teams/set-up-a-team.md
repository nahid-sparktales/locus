# Set Up a Team

Create profiles, define a bounded team, and explicitly allow hosted routing.

Open Settings → Agents & Teams.

## 1. Create agent profiles

A profile defines:

* name and role;
* exact provider account and model;
* role instructions and capability tags;
* read-only, workspace-write, or Computer Control ceiling;
* standard tool groups and explicit MCP allowlists; and
* timeout, token, call, and optional estimated-cost limits.

Use **Test Connection** before adding a profile. Eligible routes include Ollama, ChatGPT-plan, OpenAI API, Claude, Kimi, and compatible endpoints. ChatGPT-managed teams keep the Locus team contract rather than Codex-native Solo behavior.

## 2. Define the team

Choose one dispatcher, an optional fallback dispatcher, one write-capable Lead Writer, any additional ordered writers, and read-only specialists or reviewers. Configure maximum jobs, rounds, simultaneous calls, total calls, metered tokens, and estimated cost.

New teams use adaptive Locus execution with bounded delegation. The optional OpenAI Responses beta appears only for an eligible OpenAI API GPT-5.6 dispatcher, never a ChatGPT-managed account. If it is unavailable, Locus pauses and offers to run with the Locus engine; billing and execution never switch silently.

## 3. Allow hosted routing

Review Settings → Agents & Teams → Automatic Hosted Routing. Consent names the provider accounts that a dispatcher may use without another routing prompt. It does not grant tools, raise an access ceiling, or bypass ordinary permissions.

## Starter team

A practical first team uses:

* one local or inexpensive dispatcher;
* one read-only researcher;
* one primary writer;
* one read-only reviewer.

Keep initial budgets small until the routing and evidence match your expectations.
