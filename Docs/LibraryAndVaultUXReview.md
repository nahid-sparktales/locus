# Library, Identity Vault, and viewer UX review

The review focused on finding saved work, understanding document versions, reading comfortably, and acting on images without leaving the current task.

| Surface | Friction found | Change |
| --- | --- | --- |
| Image previews | Generic previews lacked discoverable zoom, fit, and pan controls. | A shared image viewer offers zoom percentage, fit, actual size, pinch zoom, drag to pan, dimensions, and transparency/light/dark backgrounds. |
| Images in chat | A small Open action was the main route to a larger preview. | The image itself opens the viewer, and action labels are more readable. |
| Output library | Images were hard to identify, preview space was constrained, and export was buried. | Thumbnails, name/date sorting, a narrower file list, visible Export, and an expanded preview. |
| Search | Empty search results could look like an unused library or vault. | Clear no-result messages, reset actions, whitespace-tolerant queries, and selection recovery after filtering. |
| Document viewer | PDF page indicators could drift from scrolling; Markdown displayed as source; extracted text replaced Office layouts. | PDF controls follow the actual page, with page jump and zoom. Markdown defaults to a reading view; Office files offer Original/Text views. |
| File viewer | Small type and unlabeled actions made longer reading difficult. | Larger default text, text-size controls, labeled actions, and flexible sizing. |
| Vault onboarding | Empty screens described features without a direct next step. | Contextual explanations and profile/document/signature creation actions. |
| Vault documents | Historical versions crowded the list, with little context about ownership. | Latest versions by default, an all-versions toggle, linked profiles, dates, and explicit Preview actions. |
| Profile editor | Long forms were hard to scan, and a new profile offered a meaningless Delete action. | Find-a-field search, optional-field guidance, save errors inside the editor, and Delete only for existing profiles. |
| Vault accessibility | The container identifier masked individual controls. | Explicit accessibility containment preserves the identity of each control. |

Private PDF and image previews receive decrypted bytes in memory. They do not create decrypted preview files or enter the workspace thumbnail cache. Existing sharing approvals, encrypted storage, immutable versions, and lock behavior remain in place. GIFs retain their Quick Look presentation.

## Verification

- Debug build and design-system audit passed.
- All 34 selected native tests passed: output storage, document search, file viewing, vault storage, and vault coordination.
- All 10 targeted UI tests passed across focused runs: library draft preservation, search recovery, version comparison, PDF navigation, image zoom/expansion, image actions in chat, onboarding navigation, profile editing, and private document/signature previews.
- The expanded-image test checks the rendered fixture pixels, not just the presence of toolbar controls.
- Vault UI checks use demonstration records in memory and a separate test app identity. The installed app and personal vault are not used as fixtures.
