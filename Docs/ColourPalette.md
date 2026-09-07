# Locus colour palette

The desktop interface uses warm paper and charcoal, restrained content colours,
and a brighter user-selected brand accent. `Locus/Theme.swift` owns the palette
for both SwiftUI and AppKit.

## Colour roles

| Role | Light | Dark | Used for |
| --- | --- | --- | --- |
| Primary text | Warm near-black | Warm ivory | Titles and emphasis |
| Secondary text | Soft charcoal | Warm light gray | Prose, outputs, editor text |
| Tertiary text | `#56594F` | `#ADA89A` | Metadata, comments, placeholders |
| Sage | `#46613E` | `#A6BB96` | Content links, strings, success, additions |
| Blue | `#3F5B75` | `#9AAEC4` | Functions and informational indicators |
| Mauve | `#785570` | `#C1A4BD` | Keywords and purple note formatting |
| Teal | `#396B69` | `#92B9B5` | Types |
| Amber | `#735627` | `#CDB382` | Numbers and warnings |
| Clay | `#834B37` | `#D39F87` | Coral note formatting and attention |
| Red | `#963D36` | `#E69890` | Errors, destructive actions, removals |

The accent fill and logo preserve the user's chosen colour. Accent text mixes
that colour toward neutral ink and is contrast-adjusted against all four app
surfaces. Success and diff colours retain their meaning when the accent changes.

Selection uses an opaque, softly tinted background. Its strength is limited so
built-in text and syntax colours remain readable for every accent and appearance,
without depending on the surface beneath it. Inactive selection is quieter.

## Audit coverage

- Conversation prose, links, code, tables, tool output, and diffs share semantic roles.
- File/document previews and the terminal use the same palette. Terminal black
  and white retain their ANSI identities for programs that specify both foreground
  and background colours.
- Settings, sidebar controls, tabs, badges, forms, Teams controls, and empty states
  use theme colours instead of macOS default colours or literal white text.
- Plain editors and native account fields have explicit text/caret colours.
- Notes map built-in formatting colours at display time. Saved archives, undo,
  and custom imported colours are preserved.
- Exported chat PDFs use fixed light-palette text suitable for white pages.

Authored document/browser content, annotation swatches, provider logos, artwork,
and test fixtures keep their intentional colours.

## Verification

Existing feature, accent propagation, notes, and selection tests cover appearance
updates and editor behaviour. Contrast checks cover semantic text on all four
surfaces, soft status badges, and selections using all seven presets plus extreme
custom colours, in both appearances and window focus states. The minimum tested
normal-text contrast is 4.5:1.
