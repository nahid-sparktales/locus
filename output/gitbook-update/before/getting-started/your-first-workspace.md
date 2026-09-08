> For the complete documentation index, see [llms.txt](https://locus-3.gitbook.io/locus-docs/llms.txt). Markdown versions of documentation pages are available by appending `.md` to page URLs; this page is available as [Markdown](https://locus-3.gitbook.io/locus-docs/getting-started/your-first-workspace.md).

# Your First Workspace

Open a project folder, choose a model, and complete your first supervised Locus 2.1 request.

![A Locus workspace with the workspace list, model route, composer modes, and Files inspector visible](https://831891047-files.gitbook.io/~/files/v0/b/gitbook-x-prod.appspot.com/o/spaces%2FdQ03BivzJFZ7fKsPFhiD%2Fuploads%2FZa56hVwenjE31NrrY8HW%2Flocus-v2-workspace.png?alt=media)

{% stepper %}
{% step %}

### Open or create a folder

Choose **Add Existing Folder…** or **New Workspace Folder…**. Locus groups chats by their real folder and remembers the most recent chat in each workspace.
{% endstep %}

{% step %}

### Choose a model route

Use local Ollama for on-device work, sign in with an eligible ChatGPT plan, or add an API provider under Settings → Models & Providers. Locus never silently switches from local or plan access to a paid API route.
{% endstep %}

{% step %}

### Pick a mode

Use Just Chat for conversation-only work. Work can inspect, plan, implement, and delegate bounded read-only research. Plan stops at an approval boundary. Grill asks one focused question at a time and never modifies the project; when the shared understanding is approved, implementation continues in Work.
{% endstep %}

{% step %}

### Send a bounded first task

Try: “Read the README and summarize how to run the tests. Do not change files or run commands.”
{% endstep %}

{% step %}

### Review the evidence

Open Overview for sources and outputs, Files for project content, Changes for the real Git tree, and Runs for durable Solo or team history.
{% endstep %}
{% endstepper %}

## Workspace behavior

Chats autosave locally and can be organized into nested folders. Add a named checkpoint before a risky conversation change. Use **Hand Off to Worktree** or **Duplicate with Worktree** when implementation should happen in an isolated Git checkout.

Press ⇧⌘9 to open the Notebook and find every note associated with this workspace, its chats, the shared note, and any older note that can no longer be linked to an owner.
