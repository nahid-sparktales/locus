# Native Agent Worlds visual verification

Completed October 5, 2026 through the supported native CUA accessibility/screenshot interface. The target was only the explicitly disposable application `io.sparktales.agent-worlds-native-parity`, PID 86954, at `/tmp/locus-agent-worlds-ui-fixture/AgentWorldsNativeParity.app`. The selected window was `Agent Worlds · tmp`. The user's already-running Locus instance was never selected or operated.

The native owner launched the current app build with `LOCUS_UI_TESTING=1` and `LOCUS_UI_TESTING_AGENT_WORLD_ROOT` pointing at the safely extracted exact candidate from independent source `68a60d4`, ZIP SHA-256 `090c697ed4c4c16f7bb0a4c284fe1cfead62cb7e7b335862c6e5da483c5c3421`. The app's guarded fixture supplied Atlas, Nova, Echo, Orion, Sage and Pip; visual defaults were nonpersistent and model dispatch refused execution. No messages were submitted, providers/accounts connected, or real user data modified.

| Interaction | Observed native result | Evidence under `agent-worlds-verification/` |
| --- | --- | --- |
| Open installed world | WKWebView displayed the loaded ocean, islands, six ships/status badges and communicator; native roster showed ship artwork/home/status and Connected LOCAL LINE. URL was confined `locus-screen://plugin/ui/index.html`. | `native-local-line.png` |
| Select Atlas | Native chat preview opened and the world focused the selected ship. | Accessibility observation |
| Ship style | Native menu showed Automatic plus fifteen plugin-provided designs. Choosing Thousand Funny changed Atlas's native card and world placement metadata. | `native-camera-zoom.png` |
| Full workspace | Captain's Quarters opened with the retained deck illustration and native crew/workspace controls. | `native-quarters.png` |
| Start synthetic chat | Fixture transcript, composer and native model/permission controls appeared beside Files, Agent and Browser panels. No message was sent. | `native-chat-tools.png` |
| Wano shortcut | Native settings selected Wano; matching background and purple palette appeared while keeping the existing chat/tools. | `native-wano-chat.png` |
| Task board | Board inspector appeared beside the chat with native columns and empty-state controls. No card created. | `native-board.png` |
| Calendar | Native calendar displayed October 2026, no connected account and no events; existing chat remained visible. | `native-calendar.png` |
| Appearance / deck | Ocean blue selected the default deck artwork and blue style. Hide workspace revealed it; Show workspace restored the same transcript and Calendar panel. | `native-ocean-deck.png` |
| Return / camera | Return to world restored the map. Scrolling over the world zoomed into detailed models; Reset view returned to the whole map with its accessibility announcement. | `native-camera-zoom.png` |
| Activity routing | Clicking the embedded communicator opened the real native Activity Center sheet; closing it returned to the world. | `native-activity.png` |

The Activity Center correctly exposed its unavailable state because this isolated visual fixture has no live backend activity service. The native roster's zero actual activity items and the renderer's one synthetic status requiring attention are different fixture inputs. This verifies routing/presentation, not live task fetching or permission resolution. New Agent remained disabled in this fixture.

The actual visible app closes the physical-visibility gap left by the hidden WKWebView structural test. Screenshots preserve the native window layout, chat/tools composition and artwork; they are not frame-identical comparisons with the browser baseline, and do not claim CPU/GPU or startup budgets. Existing browser baseline/candidate evidence and native automated tests provide the complementary checks. The disposable app was left running after capture for the native owner to stop deliberately.
