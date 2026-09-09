> For the complete documentation index, see [llms.txt](https://locus-3.gitbook.io/locus-docs/llms.txt). Markdown versions of documentation pages are available by appending `.md` to page URLs; this page is available as [Markdown](https://locus-3.gitbook.io/locus-docs/getting-started/install-locus.md).

# Install Locus

Requirements, Locus 2.1 installation, ChatGPT components, and update channels.

## Requirements

* Apple Silicon Mac
* macOS 14 or newer
* One model source: Ollama with a tool-capable model, an eligible ChatGPT plan, or a supported API account

Locus includes its Python agent runtime. You do not need Python, Homebrew, Rust, Codex CLI, the Codex app, or the ChatGPT app. Ollama and model weights are not bundled.

{% stepper %}
{% step %}

### Download the app

Download **Locus-macOS.zip** from [locushost.co](https://locushost.co) or [GitHub Releases](https://github.com/nahid-sparktales/locus/releases/latest). The direct download is about 62 MB.
{% endstep %}

{% step %}

### Move Locus to Applications

Unzip the archive, move Locus to Applications, and open it. The release is signed and notarized.
{% endstep %}

{% step %}

### Choose a workspace and model

Select a project folder, then use local Ollama, sign in with a ChatGPT plan, or add an API-backed provider under Settings → Models & Providers.
{% endstep %}

{% step %}

### Send a first request

Start with Just Chat for conversation-only work, Work for adaptive agentic work, Plan for a reviewable plan, or Grill for a one-question-at-a-time interview before implementation.
{% endstep %}
{% endstepper %}

## ChatGPT-plan component

ChatGPT-plan accounts use two helpers from OpenAI's Codex project. They are not included in the direct download because most users never need them. When you add a ChatGPT-plan account, Locus offers a one-time download of about 104 MB, using about 268–270 MB when installed.

The archive checksum and every helper's SparkTales code signature are verified before installation. A failed verification installs nothing and leaves the previous component untouched. Remove the component from Settings → Updates to reclaim the space; adding a plan account can install it again.

The Mac App Store build bundles these helpers because App Store rules do not allow downloading executable code.

## Updates and build differences

Direct-download builds check the signed stable release feed and can install an update when Locus quits. Mac App Store builds update through Apple.

The direct build can offer guarded Computer Control, local stdio MCP, Git fetch/pull/push, SSH/Keychain-backed Git operations, and the Locus Vault private alpha. The sandboxed App Store build omits capabilities it cannot safely access and keeps every wallet gate off, while Browser remains available in both.
