**English** | [中文](./REFACTORING.zh-CN.md)

# Large-File Split Plan (0.3.3 cleanup)

> Goal: break the 900+ line files into single-responsibility smaller files, so review / navigation / AI collaboration
> no longer have to scroll through a thousand lines.
> This document is a **plan**, not a completed item — read "Execution Discipline" before you start.

## Execution Discipline (follow on every cut)

1. **Pure move first**: the first cut is always "move the whole block of code into a new file as-is", with zero behavior
   change; improvements are left for the second cut.
2. **One file at a time**: a commit splits only one file, and the build + 250+ tests must all pass before touching the
   next one.
3. **Minimal access-level relaxation**: only promote `private` to `internal` after it crosses a file boundary, and
   comment at the declaration why.
4. **New Core files must be registered in the `sources` list of `Package.swift`** (an explicit list; missing one makes
   SwiftPM fail to compile outright — xip already hit this).
5. **Don't mix features**: don't sneak a bug fix or a UI change into a split commit (A10/A14).
6. Historical precedents for reference: GPGBackend (#82), ArchiveExtractionCoordinator (#83), ExternalExtractWindow
   (#84), ArchiveBrowserModel (#86), ActivityView → ActivityTaskRow (0.3.3, `f01814f`).

## Current State (2026-06-13, largest to smallest)

> ⚠️ This split plan is **not yet executed**. Since the last snapshot, most large files have continued to grow and a few
> new oversized files have appeared (the table below is refreshed to the current line counts); `FileTable`'s inline
> rename has already been extracted to `FileTableEditing.swift`, but the main file still exceeds 1800 lines. The split
> recipes (P1–P4) remain valid; when resuming, work cut by cut following the "Suggested Cadence" below.

| File | Lines | Status |
|---|---:|---|
| Features/ArchiveBrowser/FileTable.swift | 1824 | 🔴 To split (P1); FileTableEditing already extracted |
| ArchiveBrowserModel+TestHashBenchmark.swift | 1774 | 🟡 New large file (test / hashing / benchmark — three responsibilities) |
| ArchiveBrowserModel+CreateExtract.swift | 1622 | 🟡 To split (P3) |
| App/ContentView.swift | 1543 | 🟡 Already has tasks #87/#92 |
| ArchiveBrowserModel+FileOps.swift | 1457 | 🟡 Already has task #101 |
| Features/Welcome/WelcomeAssistantView.swift | 1423 | 🟡 To split (P4) |
| Features/Settings/Panes/GPGPane.swift | 1383 | 🟡 Already has task #96 |
| Core/AppPreferences.swift | 1334 | 🟡 To split (P2) |
| ArchiveCreationOptionsView.swift | 1228 | 🟢 Low priority |
| Features/ArchiveBrowser/ArchiveTable.swift | 875 | 🟢 Partially split (ArchiveColumn moved out) |
| ArchiveExtractionCoordinator.swift | 847 | 🟢 Already split once in 0.3.0 |

Threshold reference: >900 lines must be split; 600–900 lines depends on cohesion; <600 lines leave alone.

## Per-File Split Recipes

### P1 — FileTable.swift (1349 lines)

Four responsibilities live in one file. Split into four files in the same directory, all pure moves:

| New file | Contents | Estimated lines |
|---|---|---:|
| `FileTable.swift` (kept) | SwiftUI View + representable + the Coordinator's data source / selection / column management | ~450 |
| `FileTableMenu.swift` | The entire context-menu construction starting at `menuNeedsUpdate` + all `@objc` actions (`extension FileTable.Coordinator`) | ~420 |
| `FileTableDragDrop.swift` | Drag-out (file promise / sourceOperationMask) + drag-in (validateDrop / acceptDrop / caching) (`extension`) | ~220 |
| `FileTableEditing.swift` | Inline rename (textField delegate / Esc cancel / commit) | ~180 |

Risk: the Coordinator's `private` members are referenced by the extension → promote to internal; the helper computed
properties referenced by the menu must move together with the menu.

### P2 — AppPreferences.swift (1203 lines)

Three sections, naturally splittable:

| New file | Contents |
|---|---|
| `AppPreferences.swift` (kept) | The `Key` constant table + defaults handle + basic read/write |
| `AppPreferences+Accessors.swift` | Per-domain getters/setters (column toggles / launch location / GPG / Activity Center …) |
| `AppPreferences+Backup.swift` | `exportableUserDefaultsKeys` / `exportableSnapshot` / `exportablePayload` / `importPayload` / restore defaults |

⚠️ All three are in the SwiftPM target; the `Package.swift` sources must be updated to add two lines.
⚠️ The backup-related test (PreferencesPayloadCodecTests) is the regression net for this area — run it after splitting.

### P3 — ArchiveBrowserModel+CreateExtract.swift (1078 lines)

Split by verb: `+Create.swift` (create-dialog orchestration / performCreateArchive / adding files into an archive) and
`+Extract.swift` (extraction orchestration / safety-check preamble / siz·szs specialized paths). For the small shared
utilities (target-path computation, etc.), copy and judge first: only put them in `+CreateExtractShared.swift` if both
sides actually use them, to avoid opening a third file for two lines of code.

### P4 — WelcomeAssistantView.swift (1051 lines)

The container (paging / progress / footer / hero) stays in the main file; the 11 `Welcome*Step` subviews move by page
into the `Welcome/Steps/` directory (one file per page, with 2–3 steps in the same file). `WelcomeStepShell` is promoted
to internal for sharing.

### Already Assigned Task Numbers (pick up the task directly when executing)

- **#87/#92** ContentView: move the sheet routing table out into `ContentSheetRouter`, and move the external-open
  (URL scheme / NSService) routing out.
- **#96** GPGPane: extract `GPGPaneModel` (state + action orchestration), leaving the View with only rendering.
- **#101** FileOps → `FileOperationController` (phase 3 of 0.3.0's #86, moving by operation family + manual testing).
- **#91** ArchiveTransferModels move to Tasks/ or Core/.

### Low Priority (with reasons)

- `ArchiveTable.swift` 956 lines: ~170 of those are the `ArchiveColumn` enum (four switches); just move them to
  `ArchiveColumn.swift` symmetric with FileColumn — the rest of the Coordinator's cohesion is acceptable.
- `ArchiveCreationOptionsView.swift` 864 lines: just finished #115 template consumption; wait for the feature to
  stabilize before splitting the 7z advanced section.
- `ArchiveExtractionCoordinator.swift` 814 lines: split once in 0.3.0; what remains is the conflict UI + safety flow,
  which is cohesive.

## Suggested Cadence

Fit 1–2 cuts into each 0.3.x (separate from feature commits), in order P1 → P2 → P3 → P4 → the numbered tasks.
After all are done, the expectation is: the repository no longer has any Swift file over 900 lines, and the per-file
average in the Features layer is < 400 lines.
