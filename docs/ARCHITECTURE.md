**English** | [中文](./ARCHITECTURE.zh-CN.md)

# SimpleZip Architecture Notes

SimpleZip is a native macOS app with a SwiftUI/AppKit UI shell and a command-line backend layer. The project has grown
beyond a small ZIP wrapper, so this document records the ownership boundaries between the major types.

> For a full code map (where each subsystem lives, build/test commands, and how to add a feature) see
> [`docs/DEVELOPMENT.md`](DEVELOPMENT.md). This file is the narrower "who owns what state" reference.

## Current State

The boundaries below have been extracted — this section reflects the shipped layout, not a plan:

- `ArchiveBrowserModel` is the UI-facing state model, split by domain into 12 files under
  `Features/ArchiveBrowser/ArchiveBrowserModel/` (a base plus `+Navigation`, `+Loading`, `+CreateExtract`, `+FileOps`,
  `+OperationLifecycle`, `+Sort`, `+SafetyPassword`, `+SZSAndDiskImage`, `+GPG`, `+Undo`, `+TestHashBenchmark`).
- `ArchiveSession`, `FileBrowserService`, and `ArchiveOperationRunner` have been extracted from the model and live in
  `Features/ArchiveBrowser/`. Do not push backend or filesystem ownership back into `ArchiveBrowserModel`.
- `ArchiveService` is the backend facade/router (`ArchiveService.swift` + `+Arguments` + `+Parsing`). It dispatches to
  the per-format backends in `Core/Backends/`.
- The backend split is done: `Core/Backends/` holds the `ArchiveBackend` protocol plus `SevenZipBackend`,
  `NativeZipBackend`, `RarBackend`, `DiskImageBackend`, `XIPBackend`, and `GPGBackend` (itself split into per-concern
  extension files: `+Discovery`, `+Keyring`, `+KeyManagement`, `+KeyLifecycle`, `+KeyCreation`, `+Keyserver`,
  `+CryptoOperations`, `+Parsing`). `BackendProcessRunner` wraps subprocess spawn, output capture, and cancellation.
- `ArchiveExtractionCoordinator` separates merge/conflict behavior from raw backend extraction.
- `TemporaryResourceManager` owns temporary directories used for opening archive entries outside the app.
- SwiftPM target `SimpleZipCore` exposes testable core logic (the files listed in `Package.swift`'s `sources:`). Xcode
  has a `SimpleZipCoreTests` scheme that runs the same SwiftPM suite.
- `Features/Intents/` holds the App Intents / Shortcuts / Siri surface and the `IndexedEntity` types that feed
  CoreSpotlight (ledger, tasks, settings, cached archives, archive files). It is a read-side adapter over existing app
  state and the `SettingToggleRegistry` whitelist — it never owns archive or filesystem logic, and the one write it can
  perform (toggling a *safe* setting) goes through that whitelist.
- `Features/AI/` holds the macOS-26 on-device assistant (FoundationModels). It is **strictly read-only and additive**:
  it explains reports, grades risk (`Core/ArchiveRiskScore`), and scans for sensitive files / near-duplicates
  (`Core/SensitiveFileScan`, `Core/ArchiveNearDuplicates`), but it sits entirely outside the extraction / create / delete
  path and is never given encrypted-entry contents or passphrases. The deterministic scoring lives in `Core` (testable);
  the AI only narrates it. Everything here is `@available(macOS 26, *)`-gated and degrades to nothing otherwise.

## Ownership Boundaries

### `ArchiveBrowserModel`

Keep this as the UI-facing state model only:

- current `BrowserMode`;
- file and archive selection;
- active sheets and alerts;
- status text and operation progress;
- command entry points called by views, menus, and table adapters.

It should delegate file-system work and backend work instead of implementing it directly.

### `FileBrowserService`

Home for local file browsing and file operations:

- folder listing;
- Finder tag search;
- copy, move, paste, delete-to-trash;
- drag-in and drag-to-folder handling;
- file metadata loading.

### `ArchiveSession`

State holder for one opened archive:

- archive URL;
- current archive path;
- full archive item list;
- synthetic directory generation;
- selected archive entries;
- navigation within archive folders.

### `ArchiveOperationRunner`

Coordinator for long-running work:

- one active operation task;
- cancellation;
- progress mapping;
- Details output sessions;
- status updates;
- consistent error handling.

### `TemporaryResourceManager`

Owns temporary resources with predictable cleanup:

- startup cleanup for stale `SimpleZipArchiveOpen` directories;
- per-open temporary directories for archive entry previews;
- future retention policy if edited temporary copies become write-back capable.

### Backend Layer

`ArchiveService` is a router over the backend implementations in `Core/Backends/`, all conforming to `ArchiveBackend`:

- `SevenZipBackend`
- `NativeZipBackend` (also covers tar via the system `tar`)
- `RarBackend`
- `DiskImageBackend`
- `XIPBackend` (Apple-signed `.xip`, via Apple's own `xip` tool, which verifies the signature)
- `GPGBackend`

This split keeps backend preference, sandbox helpers, version-specific behavior, and compatibility testing out of one
static type. Subprocess spawn/capture/cancellation is centralized in `BackendProcessRunner`.

### On-Device AI (separate process)

All on-device model **inference** runs outside the main app binary. The app builds Codable input DTOs and calls
`AIAgentClient.generatePass(kind:input:as:)`, which serializes one typed `generate(kind:inputJSON:languageName:)` XPC
call; the engine that actually imports `FoundationModels`, builds the prompt, runs the model and parses the result is
`AIPassEngine` in `SimpleZipAgentSupport/AIAgentService.swift`, compiled only into the agent and XPC-Service targets —
never the app. The app binary therefore creates no `LanguageModelSession`; only a read-only "is the model available"
check (`AIReportAssistant.isReady`, via `SystemLanguageModel.isAvailable`) still touches `FoundationModels`.

- **Two delivery channels, one engine.** A bundled **XPC Service** serves foreground requests on demand (launched when
  the app connects; not a Login Item, not gated by "allow in background"). A dedicated **agent** (a launchd LaunchAgent)
  runs the background index on a schedule even when the app is closed. Both link `SimpleZip/Core` as a synced source
  group and run the same `AIPassEngine`.
- **One pass = the whole thing.** Each AI pass (prompt building + model call + parsing/validation) lives entirely in the
  engine, dispatched by `AIPassKind`. The app side is a thin client: build the input DTO, send, decode the output DTO,
  fall back to deterministic behavior on failure. Report prose (`reportText`), file/archive-row suggestions, the
  AI-folder plan/review/grouping/misfit-check, and the natural-language archive/settings queries all go through this one
  contract. DTOs live in `SimpleZipAgentSupport/AIPassPayloads.swift` (shared by all three targets); passes that take
  Core rich types reference them directly because every target compiles Core.
- **Deterministic helpers stay in Core.** Redaction (`AISensitiveRedactor`), preread scoring, the action vocabulary
  (`AIVirtualNodeActionDeriver`) and the rest live in `SimpleZip/Core`; because the engine links Core, it builds prompts
  from them directly rather than having the app pass pre-formatted strings across the boundary.
- **Red line.** The agent refuses all generation when the AI master switch is off (config pushed from the app through a
  versioned file). Passwords, key material, encrypted-archive entry names, ciphertext and decrypted plaintext never enter
  a prompt — enforced where the app builds each DTO. AI only explains / classifies / suggests; it never deletes, clears a
  dangerous path, or runs a write itself.

## Refactor Principles

The major extractions above are complete. The principles still apply to future moves:

- Keep growing tests around `ArchiveService` pure logic before moving code.
- Avoid changing behavior only to make the architecture look cleaner.
- Move one ownership boundary at a time; each extraction should preserve the public workflow.
- Prefer moving pure logic into `SimpleZip/Core` (and add it to `Package.swift`'s `sources:`) so SwiftPM can test it.
