# Agent World UX audit — September 21, 2026

The world now opens the same saved-agent overview used by the regular Agent page.

| Finding | Change |
| --- | --- |
| Captain’s Quarters was a small, confusing detail pane. | A large captain’s deck popup has a searchable crew sidebar, Overview, Chat, Calendar, Task board, Connections, and native management controls. |
| Only the header looked like a deck; forms reverted to the regular theme. | The whole workspace has a generated ship-deck backdrop. Walnut/teak, cream, and brass are the default; Settings preserves an Ocean blue option. Native sheets and tools inherit the choice. |
| The central Agents destination showed an empty prompt despite having crew. | Crew overview shows every resident with status, portrait, Overview, and Chat actions. |
| Tools replaced the conversation. | Browser and the other native tools sit beside chat in a resizable split view; calendar and board shortcuts also keep active chat visible. |
| Calendar required an external account. | A persistent built-in Locus Calendar always works; connected calendars overlay it. Event and board editors support @agent tags. |
| Native roster selection did not focus the ship reliably. | A repeatable focus request follows the same camera selection path, including after theme/sector loading. |
| Agents had no editable visual identity. | Overview has a picture chooser with local thumbnail storage; the same avatar appears across the normal sidebar, picker, and world. |
| Calendar and board were buried in the inspector. | Both are direct deck destinations; board handoffs choose an agent and prepare a new chat in the world’s project. |
| Clicking a ship could create or resume a chat before the user chose an action. | Selection opens Overview. New chat and Chat are explicit. |
| The activity button used a separate web status list. | Both the sidebar and communicator open the shared native Activity Center, including live tasks, approvals, results, refresh failures, and recovery actions. |
| The selected world conversation hid work in other saved chats. | Agent status also checks the profile’s other chats in this project. |
| Agent management could default to another project. | Management opened from the world carries the world’s project. |
| Outpost duplicated the native sidebar in the map. | Native windows use a single sidebar and world menu; appearance has a native menu. |
| A narrow window squeezed several panes. | Chat expands when space is tight; Captain’s Quarters has a crew-list toggle and hides the list on narrow chat layouts. |
| Fixed home islands caused unnecessarily long travel. | New work reserves the shortest reachable free berth; active reservations and physical occupancy are respected. All fourteen islands are eligible. |
| Decorative rendezvous competed with task travel. | Working and waiting ships stay on their task routes. |
| Task movement and arrival were unclear. | Working ships have a mint halo while traveling; a lit shoreline and beacon mark work ashore. Signals follow real status and respect reduced motion. |
| Four near-bank island fronts pointed away from the channel. | Little Gradient, Alabatcha, Sabaudio, and Elbatch artwork turn 180 degrees; docks and navigation stay aligned. |
| Alabatcha was too close to Elbatch. | Alabatcha moves 4.2 world units left, with its pier, obstacle, and approach destinations. |

Validation includes route availability, simultaneous reservations, release and reorder
behavior, collision-free sailing and docking, glow lifecycle, native bridge permissions,
project/profile isolation, saved-chat activity, and Activity Center navigation.
The web build and packaged asset validation pass. The native application and test bundle
build successfully. Native tests run through the direct XCTest runner because Xcode’s
LaunchServices test launch failed on this machine.

Validation: 125 renderer tests and 142 native tests passed. Native UI review
verified the themed deck, agent overview, picture chooser and cancel behavior,
built-in calendar, project board, and shared Activity Center. The isolated
preview used fixture agents and made no model calls. Calendar and board tagging
were verified with local fixture data, including saving and reopening cards.
Live external calendar accounts were not changed. Wood and Ocean blue were
visually checked, along with the native browser beside chat.
