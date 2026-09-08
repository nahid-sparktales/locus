> For the complete documentation index, see [llms.txt](https://locus-3.gitbook.io/locus-docs/llms.txt). Markdown versions of documentation pages are available by appending `.md` to page URLs; this page is available as [Markdown](https://locus-3.gitbook.io/locus-docs/working-in-locus/mobile-schedules-and-background-work.md).

# Mobile, Schedules & Background Work

Continue work from your phone, schedule tasks, and supervise durable background activity.

Locus V2 can keep useful work available after the main window closes without turning your Mac into a cloud relay.

## Scheduled tasks

The Activity Center shows upcoming, running, paused, completed, and failed schedules. Locus can remain in the menu bar, wake an eligible local task at its scheduled time, and keep each run attached to its owning workspace and chat.

![Scheduled tasks in the Locus Activity Center](https://831891047-files.gitbook.io/~/files/v0/b/gitbook-x-prod.appspot.com/o/spaces%2FdQ03BivzJFZ7fKsPFhiD%2Fuploads%2FLEnpUeGa6zu8gv2eYLhD%2Flocus-v2-schedules.png?alt=media)

Review the model route, permission mode, recurrence, and workspace before enabling a schedule. Pause or run a schedule from the Mac or the mobile companion. Destructive operations and one-time approvals still require the appropriate interactive permission boundary.

## Managed background services

Use managed background services for dev servers, watchers, and queue workers that should outlive a single agent turn. They appear above Terminal, remain associated with their workspace, and stop only when you explicitly stop them or the owning backend quits.

## Locus Mobile

Mobile Access is off by default. When enabled, Locus creates a private TLS gateway on your Mac and pairs an iOS or Android device with a five-minute, one-use code. The companion pins the Mac certificate and connects over your LAN or Tailscale; there is no Locus cloud relay.

![Mobile Access settings](https://831891047-files.gitbook.io/~/files/v0/b/gitbook-x-prod.appspot.com/o/spaces%2FdQ03BivzJFZ7fKsPFhiD%2Fuploads%2Fh21c5hZgTNw61LLL0gTQ%2Flocus-v2-mobile-access.png?alt=media)

![Pairing Locus Mobile](https://831891047-files.gitbook.io/~/files/v0/b/gitbook-x-prod.appspot.com/o/spaces%2FdQ03BivzJFZ7fKsPFhiD%2Fuploads%2Fa09CzR1RfDZ68kbiCVgl%2Flocus-v2-mobile-pairing.png?alt=media)

The companion can:

* create and continue chats;
* follow streaming work;
* stop runs;
* answer one-time approvals; and
* run or pause schedules.

Terminal, Browser, file editing, permanent permissions, provider settings, and destructive session actions remain Mac-only. Provider credentials and local agent ports are never exposed to the phone.
