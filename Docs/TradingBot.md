# Trading Bot

Trading Bot runs the TradingAgents paper-trading desk on this Mac and lets Locus
agents start analyses and read the results. It trades paper money only and is
not financial advice.

## Install

Trading Bot is listed in this repository's marketplace, which Locus discovers
when the workspace is inside this repository. Otherwise, add this repository
(local folder or owner/repo) with **Add source** in the Marketplace tab.

Open **Settings → Extensions → Marketplace → Trading Bot**, choose
**Review & install**, check the review, then choose **Install everywhere** (or
**Install for this workspace**). Locus clones the plugin from its Git
repository. The repository is private, so Git needs GitHub credentials first
(for example, `gh auth login`).

After install, the plugin installs about 230 MB of Python packages into its data
folder in the background. The Trading Bot window shows the progress and offers
**Retry setup** if it fails. Before the first analysis, choose a model: in the
Trading Bot window, choose **Open full desk**, then **Settings**.

## Open

Choose **Work → Trading Bot…**. The window starts and stops the desk, starts
analyses, lists runs, shows the paper portfolio, and opens the full desk in your
browser. Approving or declining a proposed paper order happens here.

## Agents

Agents find the tools through `search_extension_tools` (search for "trading"):

- `trading_status`, `trading_list_runs`, `trading_get_run`, `trading_portfolio`
  are read-only and run without an approval prompt. If the desk is stopped,
  the last three start it in the background, and it keeps running afterwards.
- `trading_start_analysis` and `trading_run_action` (stop, resume, decline) ask
  for approval first.
- Approving a paper order is never available to agents; only you can approve it
  in the Trading Bot window.

The bundled `trading-bot` skill describes the workflow. ChatGPT native mode does
not expose plugin tools.

## Data

Setup, logs, runs, and the portfolio live in
`~/.ollama-code/extensions/plugins/data/<marketplace>-trading-bot/`. This
includes the desk's settings and any model API keys you save there. LocusX keeps
it under `~/Library/Application Support/LocusX/Agent/extensions/plugins/data/`.

The desk keeps running in the background until you stop it in the Trading Bot
window; uninstalling the plugin stops it within a few seconds. Uninstalling
leaves the data folder in place; delete it to remove the settings and keys.
