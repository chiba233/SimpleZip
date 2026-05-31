# Contributing to SimpleZip

Thanks for helping make SimpleZip better.

SimpleZip is still early, so the most valuable contributions are focused fixes that improve real archive workflows:
opening archives, navigating nested folders, creating archives with predictable options, extracting selected files,
hashing, file associations, and macOS-native usability.

## Development Setup

Requirements:

- macOS 13.0 or newer.
- Xcode.
- Optional: `sevenzip` from Homebrew.

```bash
brew install sevenzip
```

Build:

```bash
/usr/bin/env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcodebuild \
  -project SimpleZip.xcodeproj \
  -scheme SimpleZip \
  -configuration Debug build
```

> For the full code map, layer architecture, subsystem locations, and the per-change verification matrix, see
> [`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md).

## Project Layout

Important files:

- `SimpleZip/App/SimpleZipApp.swift` — app entry and menu commands.
- `SimpleZip/App/ContentView.swift` — main window composition.
- `SimpleZip/Core/ArchiveService.swift` — command-line archive backend.
- `SimpleZip/Core/*.swift` — testable core models, options, preferences, localization helper, and safety logic.
- `SimpleZip/Features/ArchiveBrowser/ArchiveBrowserModel/` — main state and user actions, split by domain across 10 files.
- `SimpleZip/Features/ArchiveBrowser/FileTable.swift` — folder table.
- `SimpleZip/Features/ArchiveBrowser/ArchiveTable.swift` — archive table.
- `SimpleZip/Features/ArchiveOperations/*.swift` — archive creation and extraction sheets/coordinators.
- `SimpleZip/Features/Hashing/*.swift` — hashing models, service, and result UI.
- `SimpleZip/Features/Benchmark/*.swift` — 7-Zip benchmark UI.
- `SimpleZip/Features/Settings/*.swift` — preferences and file association UI.
- `SimpleZip/*.lproj/Localizable.strings` — localization.

## Code Style

- Keep modules small and named by responsibility.
- Prefer existing patterns over introducing a new abstraction.
- Add Chinese comments where they help explain archive or macOS-specific behavior.
- Keep macOS 13 compatibility unless the deployment target is intentionally changed.
- Avoid SwiftUI APIs that require newer macOS versions.
- Do not move unrelated code while fixing a narrow issue.

## Archive Backend Notes

- ZIP uses macOS built-in tools where possible.
- 7z and non-ZIP formats depend on `7zz` / `7z`.
- The bundled backend accepts binaries copied to `Contents/Resources/7zz` or `Contents/Resources/Tools/7zz`.
  During development, `SimpleZip/Tools/7zz` is the intended source location.
- Settings should keep showing the selected backend and detected 7-Zip version when archive backend logic changes.
- Any new archive command should:
  - avoid shell string interpolation;
  - pass arguments through `Process.arguments`;
  - preserve paths with spaces;
  - report command stderr clearly through `ArchiveError`.

## Localization

Ten languages ship: `en`, `zh-Hans`, `zh-Hant`, `ja`, `ko`, `de`, `es`, `fr`, `ru`, `th`.

Hand-maintain `en` and `zh-Hans` when adding UI text — add the new key to both. The other eight fall back to `en`
automatically and are translated before a release.

Validate strings before submitting:

```bash
plutil -lint SimpleZip/*.lproj/Localizable.strings Info.plist
```

## Before Sending a Change

Run:

```bash
plutil -lint SimpleZip/*.lproj/Localizable.strings Info.plist

/usr/bin/env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcodebuild \
  -project SimpleZip.xcodeproj \
  -scheme SimpleZip \
  -configuration Debug build
```

Also manually check the affected workflow in the app when the change touches UI or archive commands.

## Good First Areas

- More archive creation formats.
- Better overwrite conflict UI.
- Password prompts for encrypted archive extraction.
- Drag-and-drop into archives.
- More detailed archive metadata.
- Unit tests around path filtering and archive list parsing.
