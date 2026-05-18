# SimpleZip Architecture Notes

SimpleZip is currently a native macOS app with a SwiftUI/AppKit UI shell and a command-line backend layer. The project
has grown beyond a small ZIP wrapper, so this document records the intended ownership boundaries before larger
refactors begin.

## Current State

- `ArchiveBrowserModel` owns too much: view mode, selections, sheet state, file browsing, archive browsing, clipboard
  operations, drag-and-drop actions, operation progress, DMG sessions, and temporary open directories.
- `ArchiveService` is the main backend facade. It handles routing and implementation details for 7-Zip, native ZIP,
  tar, RAR, and DMG operations.
- `ArchiveExtractionCoordinator` already separates merge/conflict behavior from raw backend extraction.
- `TemporaryResourceManager` owns temporary directories used for opening archive entries outside the app.
- SwiftPM target `SimpleZipCore` exposes testable core logic. Xcode has a `SimpleZipCoreTests` aggregate target that
  runs the same SwiftPM suite.

## Desired Boundaries

### `ArchiveBrowserModel`

Keep this as the UI-facing state model only:

- current `BrowserMode`;
- file and archive selection;
- active sheets and alerts;
- status text and operation progress;
- command entry points called by views, menus, and table adapters.

It should delegate file-system work and backend work instead of implementing it directly.

### `FileBrowserService`

Future home for local file browsing and file operations:

- folder listing;
- Finder tag search;
- copy, move, paste, delete-to-trash;
- drag-in and drag-to-folder handling;
- file metadata loading.

### `ArchiveSession`

Future state holder for one opened archive:

- archive URL;
- current archive path;
- full archive item list;
- synthetic directory generation;
- selected archive entries;
- navigation within archive folders.

### `ArchiveOperationRunner`

Future coordinator for long-running work:

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

`ArchiveService` should eventually become a router over backend implementations:

```swift
protocol ArchiveBackend {
    func list(_ archive: URL) async throws -> [ArchiveItem]
    func extract(...)
    func test(...)
}
```

Planned implementations:

- `SevenZipBackend`
- `NativeZipBackend`
- `TarBackend`
- `RarBackend`
- `DiskImageBackend`

This split will make backend preference, sandbox helpers, version-specific behavior, and compatibility testing easier
without pushing more logic into one static type.

## Refactor Order

1. Keep adding tests around `ArchiveService` pure logic before moving code.
2. Extract `ArchiveSession` from archive navigation and synthetic directory logic.
3. Extract `FileBrowserService` from folder listing, tag search, and file operations.
4. Extract `ArchiveOperationRunner` only after operation state is stable across create/extract/test/hash.
5. Split backend implementations after tests cover the existing command argument behavior.

Avoid changing behavior only to make the architecture look cleaner. Each extraction should preserve the public workflow
and move one ownership boundary at a time.
