# Browser & Dev Servers

Drive real web pages, inspect applications, use guarded Autofill, and manage named development servers.

Locus turns Preview into a full browser shared by you and the agent. Tabs belong to the conversation that opened them, remain usable while the inspector is collapsed, and can be detached into a full-size window.

## What the agent can do

* Read a page as an addressable accessibility tree.
* Navigate, open background tabs, click, type, press keys, scroll, and drag.
* Target a named element or page coordinates for canvases, maps, and custom controls.
* Capture the viewport or a selected region and translate image coordinates back into page coordinates.
* Inspect console messages and network requests, wait for a single-page app to settle, and evaluate JavaScript for debugging.
* Emulate phone-sized viewports, mobile user-agent and touch capabilities, color scheme, and custom dimensions.

Every browser tool accepts a tab identifier, so a background worker can use its own page without pulling it in front of you. Element identifiers are valid only for the most recent page snapshot.

{% hint style="warning" %}
Page content is untrusted external data. Password fields and file-upload pickers are refused by ordinary typing tools. Running page JavaScript asks every time, including in Bypass mode.
{% endhint %}

## Real input and responsive layout

Clicks and keystrokes use the same AppKit event path as human input when possible. This lets gesture-gated controls, drag surfaces, search-as-you-type fields, and canvas interfaces behave normally. Settings → Browser can restore synthetic input for compatibility, but synthetic events cannot create a trusted user gesture.

Scrolling is aimed at the container under the pointer. On a headless Mac, coordinate conversion no longer depends on a connected display.

The live page follows the Browser panel as it resizes instead of behaving like a magnified canvas. Wide pages retain WebKit's native horizontal scrolling. Tabs and navigation use a quieter responsive toolbar, with less common actions grouped in one menu.

## Browser Autofill

Locus includes a Keychain-backed Autofill vault for passwords, contacts, and payment cards. Secrets stay in Keychain and are not written to ordinary app data.

Agent access is separately gated by category. The model sees the Autofill tool only for categories you enable; password use is scoped to the current site. The page still cannot read the vault directly, and ordinary browser history access is a separate permission.

## Browser controls

* ⌘T opens a tab.
* ⌘W closes the current browser tab while Browser is visible.
* ⇧⌘] and ⇧⌘\[ move between tabs.
* ⌘F finds text on the page.
* ⌘+, ⌘−, and ⌘0 change page zoom.
* The camera captures, crops, annotates, copies, saves, or attaches the visible page.

Popups become managed tabs. Downloads are quarantined in Locus storage, size-limited, and never executed. Browsing data is ephemeral by default; enable a persistent profile per workspace only when you need cookies or local storage to survive a restart.

## Wallet-free Locus

Standard Locus does not include a cryptocurrency wallet, wallet tools, or browser wallet-provider injection. Wallet functionality belongs to the separate LocusX edition. The [Identity Vault](../safety-and-privacy/identity-vault.md) is a separate feature for private profile details and documents.

## Named development servers

Create .locus/launch.json in a workspace to define repeatable servers:

```json
{
  "configurations": [
    {
      "name": "Web",
      "executable": "npm",
      "arguments": ["run", "dev"],
      "port": 3000
    },
    {
      "name": "Existing preview",
      "url": "http://127.0.0.1:4173"
    }
  ]
}
```

The agent can list configurations, start one by name, attach to an existing URL, wait for its port, and read bounded output filtered by level, search text, or line count. Starting a process always asks, even in Bypass mode.
