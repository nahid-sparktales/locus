> For the complete documentation index, see [llms.txt](https://locus-3.gitbook.io/locus-docs/llms.txt). Markdown versions of documentation pages are available by appending `.md` to page URLs; this page is available as [Markdown](https://locus-3.gitbook.io/locus-docs/models-and-accounts/usage-router-and-proxy-profiles.md).

# Usage, Router & Proxy Profiles

Understand usage, model-routing scorecards, and health-ranked proxy profiles.

Locus makes routing decisions inspectable without silently moving work to a paid or less-private provider.

## Usage & Costs

Open the sidebar menu and choose **Usage & Costs**. Filter the local run history by 7, 30, or 90 days, or view all recorded activity. The dashboard groups token activity by agent, model, provider, and workspace and links expensive runs back to the Runs inspector.

Costs are estimates based on the rates saved on agent profiles. Local Ollama usage is shown as $0. Solo rows record tokens; without an explicit rate they do not invent a dollar amount. The dashboard is not a provider bill.

## Model Router

The Router inspector compares eligible routes across:

* quality;
* reliability;
* privacy;
* latency;
* estimated cost; and
* model footprint.

The scorecard uses bounded candidate metadata and task tags. Prompt text is not sent to the scorecard endpoint. Hosted routes remain ineligible until separately allowed, and explicit teams keep their own route and budget rules.

Solo Work and Plan requests can create temporary read-only workers when parallel investigation would help. They use the selected model and fixed safety limits; the primary agent can also finish without delegation. Grill is a guided interview and does not modify the project.

## Proxy profiles

The Proxies inspector manages named HTTP, HTTPS, and SOCKS5 profiles. Assign profiles by traffic class, workspace, or provider, then choose strict tunnel and automatic failover behavior.

Health checks report latency and the externally observed exit address. With failover enabled, Locus checks the pool every minute and selects the fastest healthy standby. Strict tunnel mode ignores custom bypass entries and blocks external traffic when no configured route is available.

Loopback services and the configured Ollama host remain direct so Locus can reach its own runtime. Proxy rules apply to Locus, not to every app on the Mac.
