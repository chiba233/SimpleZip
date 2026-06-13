**English** | [中文](./DEVELOPMENT.zh-CN.md)

# SimpleZip Development Guide

> This document is SimpleZip's "code map + onboarding handbook". The project has grown from a small ZIP shell into
> 280+ Swift files and a dozen-odd subsystems, and the goal of this guide is: **let anyone (including yourself three
> months from now) find, within 10 minutes, "where the code for a given feature lives, which layers you have to touch to
> change it, and how to verify the change".**
>
> Companion docs, divided by role:
> - **This doc**: onboarding, building, the code map, layering, and the workflow for adding a feature.
> - [`docs/ARCHITECTURE.md`](./ARCHITECTURE.md): ownership boundaries (who should hold what state) and refactoring principles.
> - [`CONTRIBUTING.md`](../CONTRIBUTING.md): the condensed onboarding for outside contributors.
> - [`CLAUDE.md`](../CLAUDE.md) / `AGENTS.md` / `gemini.md`: the **hard rules** (A1–A22). They must be obeyed before changing code; this doc does not copy them, it only points to them.
> - [`SECURITY.md`](../SECURITY.md) / [`docs/SZS-FORMAT.md`](./SZS-FORMAT.md): the cryptographic design of the `.siz` / `.szs` signed containers. Required reading before changing wrap/unwrap/verify.
> - [`docs/release-checklist.md`](./release-checklist.md): the release process.

---

## 1. What it is

SimpleZip is a native macOS archive manager, written in Swift + SwiftUI/AppKit. The heavy lifting is done by command-line
backends (`7zz` / system `zip`/`tar`/`unzip` / `rar` / `hdiutil` / `gpg`), with a SwiftUI interface on top.

Deployment target **macOS 13.0+**. Do not use SwiftUI APIs that require a higher system version.

---

## 2. Environment, build, test

You need Xcode (`DEVELOPER_DIR` pointing at `/Applications/Xcode.app`). Optionally `brew install sevenzip` provides a
system `7zz`, but the repo already ships a bundled backend at `SimpleZip/Tools/7zz` for packaging.

The following are the **authoritative commands**, identical word-for-word to the "Verification Requirements" in
[`CLAUDE.md`](../CLAUDE.md); run them exactly like this:

### SwiftPM core tests (required when changing `SimpleZip/Core`)

```bash
/usr/bin/env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcrun swift test \
  --scratch-path /private/tmp/SimpleZipSwiftPM \
  -Xswiftc -module-cache-path -Xswiftc /private/tmp/SimpleZipSwiftPM/ModuleCache
```

### Xcode Debug build (required when changing App / Features / assets / localization / project settings)

```bash
/usr/bin/env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcodebuild \
  -project SimpleZip.xcodeproj -scheme SimpleZip -configuration Debug \
  -derivedDataPath /private/tmp/SimpleZipDerivedData build
```

### Localization strings syntax check

```bash
plutil -lint SimpleZip/*.lproj/Localizable.strings Info.plist
```

> The project file is `SimpleZip.xcodeproj` at the repo root (not `SimpleZip/SimpleZip.xcodeproj`). `Info.plist` is at the
> repo root. Two schemes: `SimpleZip` (the App) and `SimpleZipCoreTests` (runs the same SwiftPM test suite inside Xcode).

### Which one do I run? (verification matrix)

| What you changed | What to run |
|---|---|
| Only `SimpleZip/Core` pure logic | SwiftPM core tests |
| App UI / Features / menus / assets / localization / Info.plist / entitlements / project or build settings | SwiftPM tests **+** Xcode Debug build |
| Only docs (`*.md`) | Neither (unless the doc content depends on the real result of some new command) |

**Lint tool: not configured.** A business change's final response must state, truthfully, "lint not configured"; do not
fabricate a lint result.

---

## 3. Repository map (top level)

```
SimpleZip.xcodeproj/        Xcode project (single App target; Finder right-click integration goes through macOS NSServices)
Package.swift               SwiftPM: builds only the one library target, SimpleZipCore
SimpleZip/                  All App source + assets + localization
  Core/                     Pure logic testable by SwiftPM (see §4, §5)
  App/                      App lifecycle, main-window shell
  Features/                 UI + coordination logic for each feature subsystem
  Tools/7zz                 Bundled 7-Zip backend binary for packaging
  *.lproj/                  Localizable.strings for 10 languages
  Assets.xcassets, AppIcon.icns
Tests/SimpleZipCoreTests/   SwiftPM tests + Fixtures/ pre-recorded binary archives
Tools/                      (root) backend tools
scripts/                    build_unsigned_dmg.sh / install_rar_backend.sh / verify_appcast.sh
docs/                       this doc + ARCHITECTURE / REFACTORING / SZS-FORMAT / release-checklist / appcast.xml
Info.plist                  the App's Info.plist (root)
```

Root-level Markdown: `README.md`, `CHANGELOG.md` + `CHANGELOG.zh-CN.md` (**both must be updated on every business
change**), `GUIDE.zh-CN.md` (user-facing), `SECURITY.md` + `SECURITY.zh-CN.md`, `CONTRIBUTING.md`,
`CLAUDE.md`/`AGENTS.md`/`gemini.md`.

---

## 4. Layered architecture

```
┌─────────────────────────────────────────────────────────────┐
│  SimpleZip/App         App entry, main-window shell, external-open queue, Sparkle   │
├─────────────────────────────────────────────────────────────┤
│  SimpleZip/Features    Each feature's SwiftUI views + coordinators (UI layer)       │
│    ArchiveBrowser  ArchiveOperations  Settings  SignedManifest │
│    Welcome  Hashing  Benchmark  About  ExternalExtract         │
├─────────────────────────────────────────────────────────────┤
│  SimpleZip/Core        Pure logic: models / options / parsing / safety / backends   │  ← SwiftPM-testable
│    Backends/  ArchiveService  AppPreferences  L10n  SIZ/SZS ... │
├─────────────────────────────────────────────────────────────┤
│  Command-line backends 7zz · zip/tar/unzip · rar · hdiutil · gpg  │
└─────────────────────────────────────────────────────────────┘
```

### SwiftPM vs Xcode boundary (very important)

The `SimpleZipCore` target in `Package.swift` builds **only** the 81 files explicitly listed under `SimpleZip/Core/`
(see the `sources:` in Package.swift). App UI, `Features/`, `App/`, assets, localization, and `Tools/` are all
`exclude`-d.

Implications:
- **Move pure logic that can live in `Core` into `Core`** — that way it gets covered by SwiftPM tests. Command-argument
  construction, path normalization, parsing, safety decisions, and temporary-resource behavior most belong here.
- When adding a file in `Core`, **you must also add it to the `sources:` list in `Package.swift`**, otherwise the SwiftPM
  target won't compile it and the tests won't see it.
- UI-layer (`Features`/`App`) changes are verified with an Xcode build; SwiftPM can't test them.
- Xcode 16 uses file-system synchronized groups, so **adding/removing a `.swift` file usually doesn't require editing
  `project.pbxproj`** (the file system is the source of truth).

---

## 5. Code map: finding files by subsystem

Below is the "I want to change X, which file do I go to" quick reference. All paths are relative to the repo root.

### 5.1 Archive backends (7z / zip / tar / rar / dmg)

- `SimpleZip/Core/Backends/ArchiveBackend.swift` — the backend protocol (`list()` / `test()`).
- `SimpleZip/Core/Backends/SevenZipBackend.swift` — `7zz`/`7z`, with bundled + system binary discovery and version parsing.
- `SimpleZip/Core/Backends/NativeZipBackend.swift` — system `unzip`/`zip`/`tar` (no AES-encrypted-zip support, defers to 7zz).
- `SimpleZip/Core/Backends/RarBackend.swift` — `rar`, with user-installed / system discovery + install-script coordination.
- `SimpleZip/Core/Backends/DiskImageBackend.swift` — DMG mount/unmount via `hdiutil`.
- `SimpleZip/Core/ArchiveService.swift` — the **backend facade/router**. Dispatches list/test/extract/create to the
  concrete backend by format, handles password safety checks and cancellation. Start here when changing a backend entry point.
- `SimpleZip/Core/ArchiveService+Arguments.swift` — command-line argument construction (zip/7z/rar/tar flags). **Change
  arguments here, and try to add tests asserting the exact arguments generated.**
- `SimpleZip/Core/ArchiveService+Parsing.swift` — list-output parsing, path splitting, the synthesized directory tree for the UI.
- `SimpleZip/Core/BackendProcessRunner.swift` — subprocess wrapper (spawn / capture output / cancel by operationID). All
  backends go through it. **No shell string concatenation; arguments go through `Process.arguments`.**

### 5.2 The main browser: `ArchiveBrowserModel` and its splits

`ArchiveBrowserModel` is the UI-facing state hub, already split by domain into 12 files in one directory
(`SimpleZip/Features/ArchiveBrowser/ArchiveBrowserModel/`):

- `ArchiveBrowserModel.swift` — base class / shared state.
- `+Navigation.swift` — forward/back stack, breadcrumbs, directory expansion.
- `+Loading.swift` — pull items from the backend, populate the session, refresh the UI.
- `+CreateExtract.swift` — create/extract orchestration, temporary-file cleanup.
- `+FileOps.swift` — copy/move/delete/rename.
- `+OperationLifecycle.swift` — task lifecycle, cancellation, progress.
- `+Sort.swift` — column sorting.
- `+SafetyPassword.swift` — password-prompt flow, Keychain lookup, cached passwords.
- `+SZSAndDiskImage.swift` — `.szs` verification, DMG mount/unmount.
- `+GPG.swift` — orchestration of `.gpg` file decrypt/encrypt/sign operations (gated by `gpgEnabled`).
- `+Undo.swift` — undo/redo snapshots and replay for file operations.
- `+TestHashBenchmark.swift` — integrity test, hashing, 7z benchmark.

The three services extracted out of the Model (**don't push more backend/filesystem ownership back into the Model**,
see ARCHITECTURE.md):

- `SimpleZip/Features/ArchiveBrowser/ArchiveSession.swift` — the state of one opened archive (URL, current path, item list, synthesized directory).
- `SimpleZip/Features/ArchiveBrowser/FileBrowserService.swift` — local filesystem logic (list directories, Finder tags, autocomplete).
- `SimpleZip/Features/ArchiveBrowser/ArchiveOperationRunner.swift` — long-task scheduling (one operation at a time, a new task auto-cancels the old, cancellation propagates to the subprocess).

Main-window UI in the same directory: `ContentView` (in `App/`), `LocationBar.swift` (the address bar), `Sidebar.swift`,
`StatusBar.swift`, `FileTable.swift` (+ `FileTableEditing.swift` inline rename), `ArchiveTable.swift`,
`ArchiveColumn.swift` / `FileColumn.swift` (column definitions), `TableSupport.swift`, `BrowserNavigation.swift`,
`FolderWatcher.swift` (FSEvents folder watching).

> Column visibility now goes through the top-level "View" menu (`SimpleZipApp.swift` registers the commands) + the inline
> header right-click toggles (`makeColumnHeaderMenu` in `TableSupport.swift`), no longer in Settings. This is where the
> 0.2.0 "Group By / Sort By" work landed.

### 5.3 Create / extract dialogs

`SimpleZip/Features/ArchiveOperations/`:

- `ArchiveCreationOptionsView.swift` — the create dialog (format, compression level, encryption, exclusion rules, split volumes).
- `ExtractArchiveOptionsView.swift` / `ExtractSelectionOptionsView.swift` / `ExtractOptionsForm.swift` — the extract dialogs + shared form controls.
- `ArchiveExtractionCoordinator.swift` — extract orchestration (safety check → password prompt → backend selection → progress → merge/conflict handling).

The option models live in Core: `ArchiveOperationOptions.swift`, `ArchiveModels.swift`.

### 5.4 GPG (sign / encrypt / decrypt / key management)

- `SimpleZip/Core/Backends/GPGBackend.swift` and its 8 extension files (`+Discovery` / `+Keyring` / `+KeyManagement` /
  `+KeyLifecycle` / `+KeyCreation` / `+Keyserver` / `+CryptoOperations` / `+Parsing`), `GPGModels.swift` — GnuPG CLI
  integration: list keys, import, `--detach-sign`, `--status-fd` verification + strong fingerprint comparison, ownertrust
  parsing, `--encrypt -r` / decrypt, keyserver search/publish. **SimpleZip does not manage GPG private-key passphrases;
  that's left to `gpg-agent`** — error copy / release notes must keep emphasizing this.
- `SimpleZip/Features/Settings/Panes/GPGPane.swift` — the key-management GUI, with a strong split between "My keys / Others' public keys", generate/import/change-expiration/revoke/change-passphrase.
- Related sheets: `AddUserIDSheet` / `NewGPGKeySheet` / `ChangePassphraseSheet` / `EditExpirationSheet` / `GenerateRevocationSheet` (all in `Settings/Panes/`).

> **GPG visibility is a hard constraint (A4)**: when `AppPreferences.gpgEnabled == false`, every GPG entry point on the
> main interface must be **entirely unrendered** (not just disabled). The only exceptions are the Settings pane itself and
> the essential "open `.siz` from Finder" path. The check must be `gpgEnabled && GPGBackend.isAvailable()`, not just
> whether the backend is installed.

### 5.5 `.siz` / `.szs` signed containers

- `SimpleZip/Core/SIZArchive.swift` — `.siz`: packs `archive.<ext> + metadata.json + signature.asc` into a single tar.
  **It's only a tar shell, not a new backend (A5)**: open goes `unwrap → verify → model.openArchive(...)`, extract goes
  `unwrap → verify → the existing ExtractArchiveOptionsView renders one extra signature row`. Don't build a parallel "SIZ
  browse/extract flow".
- `SimpleZip/Core/SZSArchive.swift` — `.szs`: a GPG clearsigned JSON manifest listing the SHA256 of multiple files, for release distribution.
- UI: `SimpleZip/Features/SignedManifest/CreateSZSSheet.swift`, `SZSVerificationSheet.swift`; the `.siz` extract signature row is in
  `SimpleZip/Features/ExternalExtract/SIZSignatureSheet.swift`.
- **Before changing wrap/unwrap/verify, read [`docs/SZS-FORMAT.md`](./SZS-FORMAT.md) and the container-format section of `SECURITY.md`.**

### 5.6 Preferences (AppPreferences) + import/export

- `SimpleZip/Core/AppPreferences.swift` — all user preferences (language, startup location, overwrite behavior, preset password, safety policy, backend selection, GPG toggle…); sensitive values go into the Keychain.
- `SimpleZip/Core/PresetPasswordStore.swift` — Keychain storage for the preset password.
- `SimpleZip/Core/PreferencesPayloadCodec.swift` — import/export JSON encode/decode + schema-version validation.
  > Import semantics are "patch / merge", **not "restore backup"** (see fixed bug #21). A Keychain write failure must not
  > be disguised as success by a cache (bug #22).
- UI: `SimpleZip/Features/Settings/Panes/BackupPane.swift` (includes restore-to-defaults).

### 5.7 Settings panes

`SimpleZip/Features/Settings/`: the shell `SettingsView.swift` + `SettingsPane.swift` + `SettingsNavigation.swift` +
shared control `SettingsRowComponents.swift`. The panes are in `Settings/Panes/`: `GeneralPane`, `ArchivePane`,
`BrowserPane`, `FileAssociationsPane`, `GPGPane`, `BackupPane`, `HealthPane`, plus the backend-selection sections
`SevenZipBackendSection` / `RarBackendSection`.

> Adding a setting is "add one Form row in an existing pane", not opening a new card / building a parallel sheet (**A1 / A2**).

### 5.8 Health check / diagnostics

- `SimpleZip/Features/Settings/Panes/HealthPane.swift` + `HealthCheck.swift` — the health panel in first-launch / Settings (backend availability, file associations, 7zz/RAR/GPG status).
- `SimpleZip/Core/OperationDiagnosticsReporter.swift` — assembles the diagnostic report (backend versions, system info), with test coverage.
- `SimpleZip/Features/ArchiveBrowser/DiagnosticsCopier.swift` — one-click copy of diagnostics to the clipboard.

### 5.9 Welcome wizard / Sparkle updates / Finder integration / misc

- `SimpleZip/Features/Welcome/WelcomeAssistantView.swift` — the multi-step first-launch wizard (backup check, version check, language, startup location, defaults, preset password, Finder auto-extract, safety policy, backend check).
- `SimpleZip/App/SparkleUpdater.swift` — Sparkle EdDSA-signed updates (feed = `docs/appcast.xml`). The signing step is in `release.yml` and `scripts/verify_appcast.sh`.
- `SimpleZip/App/AppDelegate.swift` + `ExternalFileOpenQueue.swift` — handles the external-file queue for Finder auto-extract / "Open with SimpleZip"; the `@objc` NSServices handler methods for Finder right-click integration (Add to archive / Compute hash / Extract / Create ZIP·7z·TAR.GZ) are here too, declared in the `NSServices` of `Info.plist`, with titles in each `*.lproj/ServicesMenu.strings`.
- `SimpleZip/Core/L10n.swift` — the localization helper (pick a bundle by language, fall back to en).
- `SimpleZip/Core/TemporaryResourceManager.swift` — the temporary-resource lifecycle (clean up leftovers on launch, an isolated directory per open).
- `SimpleZip/Features/Hashing/` — hashing; `Benchmark/` — the 7z benchmark; `About/AboutPanel.swift` — the About panel.

### 5.10 On-device AI assistant (macOS 26, opt-in, read-only)

Apple Intelligence / FoundationModels glue. **Everything here is read-only and `@available(macOS 26, *)`-gated**: the
assistant explains, classifies, and suggests; it never deletes, never flips a setting, never approves an extraction, and
never sees encrypted-entry contents or any passphrase (it is fed counts, byte sizes, readable names, and category labels
only). It degrades to nothing on older systems and when Apple Intelligence is unavailable.

- `SimpleZip/Features/AI/AIReportAssistant.swift` — wraps `LanguageModelSession` for the human-readable report
  summaries. `AIGenerationSerializer` (an `actor`) funnels all generations through one serial gate so concurrent
  requests can't crash the model session.
- `SimpleZip/Features/AI/AIAssistSheet.swift` / `InlineAIAdvisory.swift` — the sheet and the inline advisory strip that
  present a summary; presentation only.
- `SimpleZip/Features/AI/SensitiveFileReportView.swift` + `Core/SensitiveFileScan.swift` — "does this archive carry
  credentials / keys / configs"; the pure scan + scoring lives in `Core`.
- `SimpleZip/Features/AI/NearDuplicateReportView.swift` + `Core/ArchiveNearDuplicates.swift` — near-duplicate detection
  (size + name + CRC heuristics), again pure logic in `Core`.
- `SimpleZip/Features/AI/ArchiveFinderSheet.swift` — "find a file *inside* an archive" UI, backed by the cached listings
  in `Core/ArchiveListingCache.swift`.
- Risk/grade model: `Core/ArchiveRiskScore.swift` — the A / B / C security grade (deterministic, testable; the AI only
  narrates it).

### 5.11 App Intents, Shortcuts & Spotlight (macOS 26)

The Shortcuts / Siri / Spotlight surface. Entities are `IndexedEntity`s pushed into CoreSpotlight so the **ledger,
tasks, settings, and (opt-in) archive contents** are searchable from the system — archive *file contents* are indexed
per the privacy policy (readable names only; encrypted-entry contents and passphrases are never indexed). See
[SHORTCUTS.md](SHORTCUTS.md).

- `SimpleZip/Features/Intents/SimpleZipAppIntents.swift` — the `AppShortcutsProvider` and the intent set (extract /
  create / test / verify / compare / search / inspect / create-release-package / change-setting).
- `*Entity.swift` (`ArchiveFileEntity`, `ArchiveTaskEntity`, `CachedArchiveEntity`, `ReleasePackageEntity`,
  `ReleaseWorkspacePresetEntity`, `SettingEntity`) — the `AppEntity` / `IndexedEntity` types and their `EntityQuery`s.
- `SettingToggleSnippet.swift` — the "Setting Switch" snippet UI returned by the change-setting intent; the actual write
  goes through the `SettingToggleRegistry` 3-gate whitelist, so security-sensitive settings are never reachable by voice
  or Shortcut.
- `SpotlightRoute.swift` — maps a tapped Spotlight result back to the right in-app destination.
- Tab completion for the CLI lives in `Core/CLICompletions.swift`.

---

## 6. Which layers an "open archive → browse → extract" passes through

To build your mental model (follow this chain down when chasing a bug):

1. User drags in / double-clicks an archive → `ContentView` / `AppDelegate` (external files go through `ExternalFileOpenQueue`).
2. `ArchiveBrowserModel+Loading` calls `ArchiveService.list(...)`.
3. `ArchiveService` picks the backend from `Core/Backends/` by format → `BackendProcessRunner` spawns the subprocess (e.g. `7zz l`).
4. `ArchiveService+Parsing` parses the output into `ArchiveItem` + a synthesized directory tree → stores it in `ArchiveSession`.
5. `ArchiveTable` renders; `+Navigation` handles entering/leaving directories.
6. Extract: `+CreateExtract` → `ArchiveExtractionCoordinator` (`ArchiveSafety` does path-traversal / symlink / etc. safety
   checks → prompt for a password via `+SafetyPassword` as needed → pick a backend → run via `BackendProcessRunner` →
   progress flows back through `ArchiveOperationRunner`).
7. Temporary products are registered with `TemporaryResourceManager`, cleaned up on exit / operation completion.

---

## 7. How to add a new feature (landing checklist)

> This section is the **workflow**. The specific prohibitions (don't redraw the page, don't stack DTOs on DTOs, don't
> build a parallel sheet…) are in [`CLAUDE.md`'s A1–A22](../CLAUDE.md); those are the hard rules — read them before you
> start, this doc doesn't copy them.

1. **Find the existing idiom first.** grep the file you're about to touch, see how neighboring rows/controls are written,
   and reuse it. A feature is one feature flag / one `if let` line inside the existing architecture, not a parallel
   sub-app (A1). Can you avoid creating a new file? (A12: don't blow a one-line behavior change into a 12-file diff.)
2. **Pure logic goes in `Core`.** Command-argument construction, parsing, safety decisions, path handling →
   `SimpleZip/Core/`, add it to `Package.swift`'s `sources:`, then write SwiftPM tests (command arguments should assert
   the exact flags generated).
3. **UI stays in `Features`**, doing presentation and interaction only; backend/filesystem/parsing sinks into a service.
   Don't run a backend process / filesystem scan / hashing on the main thread.
4. **State mutations on the main actor**; don't change SwiftUI-observed state from a background task. User-triggered
   archive/file/hash operations must be cancelable.
5. **Localization (A9, hard requirement):** every new user-visible string uses `L10n.text("some.key")`, and the key is
   added to **both** the two hand-maintained languages `en.lproj` **and** `zh-Hans.lproj`. The other 8 languages
   (de/es/fr/ja/ko/ru/th/zh-Hant) fall back to en automatically, translated before release. Don't hard-code English strings.
6. **No half-wired references (A8):** a model method referenced by a menu/selector must exist in the same change (even a
   stub that throws `notImplemented`); don't check in a tree that doesn't compile.
7. **Visibility gating is a hard rule (A4):** when a master toggle is off, the feature UI doesn't render (not just disabled).
8. **Update both CHANGELOGs** (`CHANGELOG.md` + `CHANGELOG.zh-CN.md`), written on the spot for each business change, not batched afterward.
9. **Run verification by the matrix** (§2), and report truthfully in the final response: lint (not configured) / which test or build ran / pass or fail / residual risk.

### Things not to touch

- **Don't hand-edit version numbers** (A6): `project.pbxproj`'s `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` and
  `Info.plist`'s `CFBundleShortVersionString` / `CFBundleVersion` are all written by CI at build time. A "version bump"
  changes only the two CHANGELOGs.
- **Use the system `temporaryDirectory` for temp dirs** (A7):
  `FileManager.default.temporaryDirectory.appendingPathComponent("SimpleZip-...-\(UUID())")`, registered with
  `TemporaryResourceManager` for cleanup. Don't write into the project directory or hard-code `/tmp/foo`.
- **Don't change user-visible behavior just to pass a test.** Tests can't be changed by default, see §8.

---

## 8. Tests and fixtures

Tests live in `Tests/SimpleZipCoreTests/` (SwiftPM, written with swift-testing, currently 50 test files and about 467
`@Test` cases). The table below is a representative selection:

| File | Coverage |
|---|---|
| `ArchiveServiceTests.swift` | Routing logic: exclusion patterns, argument splitting, split-volume size validation, compression level/method parsing |
| `ArchiveServiceArgumentsTests.swift` | Per-backend CLI flag generation (7z/zip/rar/tar, encryption, split volumes) |
| `ArchiveServiceParsingTests.swift` | Output parsing (zip/7z list formats, nested paths, directory synthesis) |
| `ArchiveServiceFixtureTests.swift` | Regression: reading the pre-recorded real archives in `Fixtures/` |
| `PreferencesPayloadCodecTests.swift` | Import/export JSON encode/decode, schema version, roundtrip |
| `OperationDiagnosticsReporterTests.swift` | Diagnostic-report assembly |
| `SIZArchiveTests.swift` | `.siz` wrap/unwrap roundtrip, metadata encoding, integrity |
| `ArchiveOperationFeedbackTests.swift` | Progress parsing from subprocess output |

`Fixtures/` are pre-recorded binary archives, accessed via `Bundle.module` for URLs (see `resources: [.copy("Fixtures")]`
in `Package.swift`), so they don't depend on `swift test`'s working directory.

**Test rules (from CLAUDE.md):**
- Don't change unit tests by default. When a test fails, diagnose and fix the **production code** first.
- If you think a test itself is outdated → first explain why and what the correct behavior should be, then change the test **only after the user approves**.
- Don't weaken assertions or remove coverage just to make verification pass.
- Prefer writing tests for pure core behavior, command-argument generation, path normalization, safety prompts, conflict decisions, parsing, and temporary-resource behavior.

---

## 9. Localization workflow

10 languages, each at `SimpleZip/*.lproj/Localizable.strings` (Finder right-click service titles are separately in
`SimpleZip/*.lproj/ServicesMenu.strings`):

`en` `zh-Hans` `zh-Hant` `ja` `ko` `de` `es` `fr` `ru` `th`

- **Two are hand-maintained: `en` and `zh-Hans`.** Add a new key to these two on the spot. The other 8 fall back to en, translated before release.
- After adding, run `plutil -lint SimpleZip/*.lproj/Localizable.strings Info.plist` to check syntax.
- After a language change, the macOS top menu bar must follow along (was bug #18, fixed).

---

## 10. Releasing

See [`docs/release-checklist.md`](./release-checklist.md) for the full process. Key points:

- Version numbers are written by CI from `RELEASE_VERSION` / `GITHUB_RUN_NUMBER`, **not by hand** (A6).
- A "version bump" = move the unreleased entries in both CHANGELOGs under a new `## X.Y.Z` heading; leave already-released sections untouched.
- Sparkle updates are EdDSA-signed, the feed is `docs/appcast.xml`; signing is done in `release.yml`, with `scripts/verify_appcast.sh` for a local self-check.
- Cryptographic changes to `.siz`/`.szs` must go through the corresponding section of `SECURITY.md`.

---

## 11. Hard-rule quick reference (see CLAUDE.md A1–A22 for detail)

| # | One line |
|---|---|
| A1 | A feature lives inside the existing dialog/page — no redraw, no parallel sub-app |
| A2 | Don't stack DTOs that mirror existing types + a mapper; let the existing type flow straight to the consumer |
| A3 | For a one-publisher/one-subscriber path don't add a new `NotificationCenter` name; use existing `@Published` |
| A4 | Master toggle off → feature UI doesn't render (not disabled); check `gpgEnabled && isAvailable()` |
| A5 | `.siz` is just a tar shell; don't over-architect it |
| A6 | Don't hand-edit version numbers |
| A7 | Use the system temp dir and clean up |
| A8 | No half-wired references; the committed tree must compile |
| A9 | Every new user-visible string needs `L10n` + keys in both en/zh-Hans |
| A10 | Match scope: a bug fix changes one branch, don't sneak in a refactor |
| A11 | User instructions are cumulative and binding; ask before contradicting them |
| A12 | Don't blow up the diff / don't add files the user didn't ask for |
| A13 | **Never rewrite git history**: no reset --hard / revert / amend / rebase / push --force / deleting or moving tags; to undo, commit forward |
| A14 | Don't reflexively revert and rewrite; make the **smallest** change that satisfies the literal request |
| A15 | Do only what was asked — don't guess, expand, or "improve"; if ambiguous, ask one precise question first |
| A16 | For a "still broken" hard bug, add logs / measure first, don't ship another guess |
| A17 | The folder-reload path is a `@Published` no-go zone (the FSEvents ~120ms storm floods the menu bar) |
| A18 | Don't block the main thread waiting on async (App target is MainActor by default); use `RunLoop.main.run`, not `dispatchMain()` |
| A19 | `Bundle.main` lies when invoked through a symlink (the CLI companion process must resolve the real bundle itself) |
| A20 | Scripted bulk edits to Swift sources must anchor on long unique snippets, and build before committing |
| A21 | A new `AppPreferences` key must be registered in both `exportableUserDefaultsKeys` and `exportableSnapshot()` |
| A22 | CHANGELOG grouped by change type (feat/UX/bugfix/improvements/misc) then split user/developer-facing; merge into the same entry for an unreleased version |
