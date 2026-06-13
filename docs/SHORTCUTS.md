**English** | [中文](./SHORTCUTS.zh-CN.md)

# SimpleZip Apple Shortcuts & Siri

SimpleZip exposes its archive operations as [App Intents](https://developer.apple.com/documentation/appintents), so you
can use them from the **Shortcuts** app and **Siri** on macOS. Every action runs on the same engines that drive the app
itself — there is no parallel automation backend — and each run is recorded in the Activity Center so you can watch
progress live and review the history later.

This document lists the actions, the entities they expose, the example phrases, and the macOS-version availability. It
documents only what the app actually ships; it does not invent commands, parameters, or behavior.

> Related automation surfaces: see [`CLI.md`](./CLI.md) for the command-line companion and
> [`URL-SCHEME.md`](./URL-SCHEME.md) for the `simplezip://` URL scheme. All three report into the same Activity Center.

## How it works

- The actions are defined in `SimpleZip/Features/Intents/SimpleZipAppIntents.swift`.
- Each action reuses the app's existing windowless core (for example `ExternalExtractRunner`, `ArchiveService`,
  `HashService`, and the Release Assistant pipeline). Shortcuts do not get a separate implementation.
- Every run opens a task in the Activity Center with the source marked as **Shortcuts / Siri**. You see the same
  progress, status, and history entry you would get from any other operation in the app.
- Shortcuts is an unattended context, so these actions **never prompt** — for a password, a destination, or a
  confirmation. Where a password might be needed (testing an encrypted archive), the action uses the saved preset
  password only when one is configured and the relevant automation preference allows it; otherwise it proceeds without
  one.
- Inputs are always real files on disk. If Shortcuts passes in‑memory data with no file location, the action rejects it
  rather than silently writing unknown data to a temporary directory.
- Output names are validated. An output name must be a single plain file name; path separators, `..`, drive letters, and
  `~` are rejected. Existing files are never overwritten — a numbered name (for example `name 2`) is used instead.

## Available actions

The titles and parameters below are exactly as defined in source.

### Extract Archive

Extracts archives the way SimpleZip's Finder auto-extract does: each archive unpacks into a uniquely named folder next to
itself (or inside the chosen destination). Existing files are never overwritten.

| Parameter | Type | Notes |
| --- | --- | --- |
| **Archives** | list of files | The archives to extract. |
| **Destination Folder** | file (optional) | When set, archives unpack inside this folder. |

Returns the produced folders as files.

### Create Archive

Compresses files into a new archive next to them, applying the same per-format defaults as SimpleZip's one-click Finder
compression. All inputs must live in the same folder; an existing archive is never overwritten — the new one gets a
numbered name instead.

| Parameter | Type | Notes |
| --- | --- | --- |
| **Files** | list of files | The files to compress. Must all be in the same folder. |
| **Format** | choice | `ZIP`, `7-Zip`, `tar`, or `tar.gz`. Defaults to `ZIP`. |
| **Archive Name** | text (optional) | Base name for the new archive. |

Returns the created archive as a file.

### Test Archive Integrity

Runs SimpleZip's integrity test on archives and reports which ones fail. Encrypted archives are tested with the preset
password when one is configured; this intent never prompts.

| Parameter | Type | Notes |
| --- | --- | --- |
| **Archives** | list of files | The archives to test. |

Returns a boolean (true when all pass) and a dialog summarizing passes or failures.

### Verify Checksums

Verifies the files listed in checksum files (SHA256SUMS, .sha256, .md5, .sfv). Paths resolve relative to each checksum
file; unsafe entries are rejected. Returns true when everything matches.

| Parameter | Type | Notes |
| --- | --- | --- |
| **Checksum Files** | list of files | The checksum manifests to verify. |

Returns a boolean (true when everything matches) and a dialog summarizing the result.

### Compare Archives

Compares the entry lists of two archives (path, size, CRC, modified, encryption). Returns true when they are identical.

| Parameter | Type | Notes |
| --- | --- | --- |
| **First Archive** | file | The first archive. |
| **Second Archive** | file | The second archive. |

Returns a boolean (true when identical) and a dialog with the added / removed / changed counts.

### Search Archive Contents

Lists an archive and returns the entries whose path contains the search text (case-insensitive). Encrypted archives whose
entry names need a password aren't listed.

| Parameter | Type | Notes |
| --- | --- | --- |
| **Archive** | file | The archive to search. |
| **Query** | text | The text to match against entry paths. |

Returns the matching entry paths as a list of text, plus a dialog with the result count.

### Inspect Archive

Inspects an archive the way the Release Assistant does — file count, total size, macOS junk, empty directories and
suspicious entry paths — without extracting. Returns true when nothing suspicious is found.

| Parameter | Type | Notes |
| --- | --- | --- |
| **Archive** | file | The archive to inspect. |

Returns a boolean (true when nothing suspicious is found) and a dialog summarizing the inspection.

### Create Release Package

Runs SimpleZip's Release Assistant headlessly: pack a build folder (junk excluded, reproducible), inspect the archive and
write SHA256SUMS — using a saved workspace preset when one is chosen. Signing as `.szs` is interactive-only and never runs
unattended.

| Parameter | Type | Notes |
| --- | --- | --- |
| **Build Folder** | file | The folder to package. Must be a directory. |
| **Workspace Preset** | Workspace Preset (optional) | A saved release workspace preset to apply. |
| **Archive Name** | text (optional) | Overrides the output base name. |

Returns the created release package as a file, plus a dialog confirming completion. Successful runs are added to the
release ledger.

### Find Archive Containing File

Searches the archives you've recently opened (their cached listings) for one whose entries match a file name — "which of
my archives has `config.yaml` in it?" — without re-opening or extracting anything. Matching uses readable entry names
only; it never reaches into an encrypted entry's contents.

| Parameter | Type | Notes |
| --- | --- | --- |
| **File Name** | text | The file name (or fragment) to look for inside cached archives. |

Returns the matching cached archive(s); tapping one opens it in SimpleZip.

### Change a Setting

Flips a SimpleZip preference by voice or Shortcut — "Turn on reproducible archives with SimpleZip" — and returns a
**Setting Switch** card showing the new state. **Security-sensitive settings are never reachable this way:** the write
goes through the same three-gate whitelist (`SettingToggleRegistry`) used by the in-app "Setting Switch", so only safe
boolean toggles can be changed; anything touching passwords, signing, or extraction safety is refused.

| Parameter | Type | Notes |
| --- | --- | --- |
| **Setting** | Setting | The setting to change (picked from a list, or matched by name). |
| **State** | choice | `On`, `Off`, or `Toggle`. Defaults to `Toggle`. |

Returns the setting's new state in a Setting Switch snippet.

## Entities

SimpleZip exposes several read-only entities to Shortcuts, Siri and Spotlight. They are read-only views of app data; they
never trigger a write or a security decision, and they never expose the contents of files inside an archive. Five of them
(**Archive Task**, **Release Package**, **Cached Archive**, **Archive File**, **Setting**) conform to `IndexedEntity` and
can be pushed into Spotlight on macOS 15+, governed by the per-surface indexing preferences in Settings → Spotlight.
Indexed archive metadata is **readable names only** — encrypted-entry contents and passphrases are never indexed.

### Archive Task

Represents one task from the Activity Center history (defined in
`SimpleZip/Features/Intents/ArchiveTaskEntity.swift`). Properties: **Source**, **Status**, **Started**. The most recent
20 tasks are suggested. This lets a shortcut reference a past operation, such as a recent extraction.

### Release Package

Represents one successful release recorded in the release ledger (defined in
`SimpleZip/Features/Intents/ReleasePackageEntity.swift`). Properties: **Version**, **Date**, **Format**, **SHA-256**,
**File Count**, **Reproducible**, **Checksums Written**. The most recent 20 releases are suggested. On macOS 15 and later
the release ledger can also be indexed into Spotlight (semantic publishing metadata only — never archive contents), when
the corresponding indexing preference is enabled.

### Workspace Preset

Represents a saved release workspace preset (defined in
`SimpleZip/Features/Intents/ReleaseWorkspacePresetEntity.swift`). Property: **Name**. It is used as the parameter picker
for the **Workspace Preset** parameter of *Create Release Package*, and supports both picking from a list and matching by
name (so a Shortcuts variable can supply the preset).

### Cached Archive

Represents an archive you've recently opened (defined in
`SimpleZip/Features/Intents/CachedArchiveEntity.swift`). Properties: **Name**, **Path**, **Entry Count**, **Last
Opened**. Backs the *Find Archive Containing File* action and, when indexed, lets Spotlight jump you straight back into a
recent archive. Only the archive's own path and readable entry names are exposed.

### Archive File

Represents a single file *inside* an archive (defined in `SimpleZip/Features/Intents/ArchiveFileEntity.swift`).
Properties: **Name**, **Path inside the archive**, **Size**, the containing archive. Surfaced by archive search and the
in-archive finder; when indexed, a Spotlight hit opens the archive at that entry. Encrypted-entry contents are never
read — only the listed name and size.

### Setting

Represents one SimpleZip preference (defined in `SimpleZip/Features/Intents/SettingEntity.swift`). Properties: **Name**,
**Category**, **Current State**. Backs the *Change a Setting* action and Spotlight "open this setting" jumps. Only
safe boolean settings are writable (the three-gate whitelist); security-sensitive settings are read-only here.

## Example phrases

These are the phrases registered with Siri and the Shortcuts app. `SimpleZip` stands for the application name in each
phrase.

| Action | Phrases |
| --- | --- |
| Extract Archive | "Extract an archive with SimpleZip" |
| Create Archive | "Create an archive with SimpleZip" |
| Test Archive Integrity | "Test an archive with SimpleZip" · "Check an archive with SimpleZip" |
| Verify Checksums | "Verify checksums with SimpleZip" · "Verify a SHA256SUMS file with SimpleZip" |
| Compare Archives | "Compare archives with SimpleZip" · "Compare two archives with SimpleZip" |
| Search Archive Contents | "Search an archive with SimpleZip" · "Search archive contents with SimpleZip" |
| Inspect Archive | "Inspect an archive with SimpleZip" · "Inspect an archive for release with SimpleZip" |
| Create Release Package | "Create a release package with SimpleZip" · "Package a release with SimpleZip" |
| Find Archive Containing File | "Find which archive contains a file with SimpleZip" · "Find an archive containing a file with SimpleZip" |
| Change a Setting | "Change a SimpleZip setting" · "Turn on a SimpleZip setting" · "Turn off a SimpleZip setting" · "Toggle a SimpleZip setting" |

## macOS availability

- The intents themselves use `AppEntity` / `EntityQuery`, which are available from **macOS 13** — the app's deployment
  target. The actions and entities therefore work on macOS 13 and later.
- The `AppShortcutsProvider` (`SimpleZipAppShortcuts`) that pre-registers the actions and example phrases into the
  Shortcuts app, Spotlight, and Siri suggestions is gated to **macOS 14 and later** (`@available(macOS 14.0, *)`). On
  macOS 13 the intents are still fully usable; they are simply not pre-registered as suggestions.
- Spotlight indexing (the `IndexedEntity` conformance on Archive Task, Release Package, Cached Archive, Archive File and
  Setting) requires **macOS 15 and later**; on older systems it is a no-op. Each surface is gated by its own preference
  under Settings → Spotlight, and indexed archive metadata is readable names only.
- *Find Archive Containing File* and *Change a Setting* are plain `AppIntent`s with no version gate, so they work on
  macOS 13 and later like the other actions.

## Notes on safety

- Actions run unattended and never prompt. Operations that would require interaction in the app — for example signing a
  release package as `.szs` — are skipped in the Shortcuts context even if a chosen preset requests them.
- Encrypted archives are handled without prompting. *Test Archive Integrity* tries without a password first and only
  retries with the saved preset password when the error indicates a password is required, a usable preset password is
  configured, and the automation preference permitting preset-password use is enabled.
- *Search Archive Contents* only lists what the archive exposes; archives whose entry names require a password are not
  listed, so their contents are never revealed.
- *Change a Setting* can only flip safe boolean preferences. The write is gated by the same three-stage whitelist
  (`SettingToggleRegistry`) the in-app Setting Switch uses; settings governing passwords, GPG signing, or extraction
  safety are not toggleable by voice, Shortcut, or Spotlight.
- For the broader project safety rules around archive handling, see [`../SECURITY.md`](../SECURITY.md).

## See also

- [`CLI.md`](./CLI.md) — the command-line companion.
- [`URL-SCHEME.md`](./URL-SCHEME.md) — the `simplezip://` URL scheme.
- [`ARCHITECTURE.md`](./ARCHITECTURE.md) — ownership boundaries and the windowless core the actions reuse.
