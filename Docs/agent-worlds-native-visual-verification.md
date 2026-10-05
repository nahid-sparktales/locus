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

## Final extracted-host pass

Repeated on October 5 after cutover, using final independent source `ec9416679a5f4929d78ae2f19acb6e4d572eb234` and ZIP SHA-256 `4a4ca458bd1e0391e2ead1b52a58977329e85c30280218e605e992808f99eff8`. The native owner provided build `12786fb4` in the uniquely identified app `io.sparktales.agent-worlds-native-final.8w2ehif4`, PID 14198, at `/var/folders/8s/h68vzwb10yg081d3vgblcx7c0000gn/T/locus-worlds-verified-ui-8w2ehif4/AgentWorldsNativeFinal.app`. UI tests were stopped during this exclusive CUA pass. The machine was macOS 26.4.1 (25E253), Apple M2 Max, 32 GiB memory. Native window captures are 2560 × 1704 pixels; picker sheets have their own dimensions.

| Check | Observed result | Evidence |
| --- | --- | --- |
| Final artifact and native host | Six synthetic native profiles; connected installed `locus-screen://plugin/ui/index.html` world; map and communicator loaded. | `native-final-map.png` |
| Detailed model textures | Camera zoom showed colored candy-island roofs, gray/tan masonry, green vegetation, pink/cream ship sails and hulls, wood decks and a black skull sail. The whole-map pale silhouettes also occur in the original browser baseline and earlier native capture; close-up colors match the earlier native camera capture. | `native-final-textures.png`, `native-final-ship.png`, `native-final-reset-reopen.png` |
| Native portrait cancellation | Selected Nova as a preview, cancelled, reopened the real picker: it still reported Selected picture: Initials. | `native-final-picture-picker.png`, `native-final-picture-cancel.txt` |
| Canonical portrait apply | Applied bundled Nova to synthetic Atlas through the native picker. Native overview, roster and chat displayed the picture. | `native-final-wano-profile.png` |
| Declarative Wano presentation | Wano artwork and purple palette loaded in native quarters around the existing overview, chat, composer and native tools. | `native-final-wano-profile.png`, `native-final-chat-board.png` |
| Cosmetic reset boundary | Reset world settings removed Wano styling; returning to the world and reopening native overview retained the avatar and the same fixture conversation. Reopened picker showed the identical Nova image as Custom character (the existing image-data representation). | `native-final-reset-reopen.png`, `native-final-picture-preserved.png` |
| Chat/tool composition | Native Board columns appeared beside the fixture transcript and composer. Browser, Files and Agent tabs remained available. No messages or cards were submitted. | `native-final-chat-board.png` |

The WebKit logs' WEBP `-50` diagnostics did not correspond to missing colors in these inspected models or missing required quarters artwork. This observation does not classify every decoder diagnostic as harmless; the detailed captures complement the packaged asset and native transport tests.

This pass exposed a concrete visual defect: after applying a portrait, the world chat-peek menu label displayed it as a large cropped strip instead of a bounded avatar (`native-final-reset-reopen.png`). The root implementation owner was notified; final visual closure requires a fixed-build follow-up capture. Portrait persistence/reset behavior itself passed.

Both disposable native apps (14198 and earlier 86954) were quit through their exact CUA app bindings; a process check confirmed both exited. All owned temporary HTTP/developer servers and browser tabs had already been closed. The actual user's Locus app was never selected or operated. These synthetic profile/chat changes remained in the UI fixture's nonpersistent stores.
