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

## Refactor Principles

The major extractions above are complete. The principles still apply to future moves:

- Keep growing tests around `ArchiveService` pure logic before moving code.
- Avoid changing behavior only to make the architecture look cleaner.
- Move one ownership boundary at a time; each extraction should preserve the public workflow.
- Prefer moving pure logic into `SimpleZip/Core` (and add it to `Package.swift`'s `sources:`) so SwiftPM can test it.
