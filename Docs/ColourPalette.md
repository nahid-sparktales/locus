# Locus colour palette

The standard desktop interface uses neutral whites, grays, and charcoal, with
restrained content colours and a brighter user-selected brand accent. The light
base no longer carries a cream/beige tint, and the dark base has no olive cast.
`Locus/Theme.swift` owns the palette for both SwiftUI and AppKit.

The October 5, 2026 refresh changes the standard light/dark surfaces, text, and
separators. Saved accents, brand/logo colours, and semantic status/syntax hues
retain their existing values. Agent World's ocean, Captain's Quarters deck, and
island palettes remain separate and intentionally keep their authored colours.

## Colour roles

| Role | Light | Dark | Used for |
| --- | --- | --- | --- |
| Canvas (`paper`) | `#FAFAFA` | `#171717` | Main workspace background |
| Structural surface (`paperDeep`) | `#F1F1F1` | `#202020` | Sidebar and structural areas |
| Panel (`panel`) | `#FFFFFF` | `#1B1B1B` | Inspector and panel surfaces |
| Raised/card surface (`white`) | `#FFFFFF` | `#282828` | Raised controls and cards |
| Primary text | `#181818` | `#F5F5F5` | Titles and emphasis |
| Secondary text | `#3D3D3D` | `#D4D4D4` | Prose, outputs, editor text |
| Tertiary text | `#5F5F5F` | `#A8A8A8` | Metadata, comments, placeholders |
| Separator (`line`) | `#DEDEDE` | `#3D3D3D` | Decorative separators |
| Strong boundary (`lineStrong`) | `#7A7A7A` | `#858585` | Boundaries that need stronger contrast |
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
- The native menu-bar companion popover shares the app's Chat/Activity palette;
  its actual light/dark rendering remains unverified because the local display
  notch prevented opening the status item.
- Plain editors and native account fields have explicit text/caret colours.
- Notes map built-in formatting colours at display time. Saved archives, undo,
  and custom imported colours are preserved.
- Exported chat PDFs use fixed light-palette text suitable for white pages.

Authored document/browser content, annotation swatches, provider logos, artwork,
and test fixtures keep their intentional colours.

## Verification

Source-derived WCAG relative-luminance calculations passed against the refreshed
palette values and their derived badge, selection, and accent formulas:

| Checked role | Pairs across both appearances | Minimum light ratio | Minimum dark ratio |
| --- | ---: | ---: | ---: |
| Semantic text on the four surfaces | 104 | 5.002:1 | 6.200:1 |
| Soft status badges | 48 | 4.682:1 | 4.789:1 |
| Strong boundaries | 8 | 3.800:1 | 3.995:1 |
| Selection text | 52 | 4.506:1 | 4.501:1 |
| Accent actions | 26 | 4.504:1 | 4.593:1 |

Primary-text contrast alone is at least 15.721:1 in light appearance and 13.523:1
in dark appearance across the four surfaces. Ordinary text checks require at
least 4.5:1; strong boundaries require 3:1. Decorative separators are not claimed
to meet the strong-boundary threshold. The check includes seven accent presets
and extreme custom colours through the existing derived-colour rules.

Syntax parsing and whitespace checks passed for the palette implementation.
These are source-derived checks, not native rendering or screenshot measurements.
Theme regression tests passed in the full 1,966-test native run. The refreshed
build passed seven companion UI cases with one explicit menu-bar skip and zero
failures. [Current light/dark fixture screenshots](CompanionTabVerification.md#native-ui-inspection-and-screenshots)
show the refreshed palette in the latest local build; they are static UI evidence,
not contrast measurements. Actual menu-popover interaction was obstructed by the
local display notch and is unverified.
Feature, accent propagation, notes, and selection tests passed in that native run;
they cover appearance updates, editor behaviour, and derived-colour contrast.
Those executed tests remain distinct from the source-derived calculation above.
