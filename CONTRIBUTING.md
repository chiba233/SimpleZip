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
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild \
  -project SimpleZip/SimpleZip.xcodeproj \
  -scheme SimpleZip \
  -configuration Debug build
```

## Project Layout

Important files:

- `SimpleZip/SimpleZip/SimpleZipApp.swift` — app entry and menu commands.
- `SimpleZip/SimpleZip/ContentView.swift` — main window composition.
- `SimpleZip/SimpleZip/ArchiveBrowserModel.swift` — main state and user actions.
- `SimpleZip/SimpleZip/ArchiveService.swift` — command-line archive backend.
- `SimpleZip/SimpleZip/FileTable.swift` — folder table.
- `SimpleZip/SimpleZip/ArchiveTable.swift` — archive table.
- `SimpleZip/SimpleZip/SettingsView.swift` — preferences UI.
- `SimpleZip/SimpleZip/*.lproj/Localizable.strings` — localization.

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
- Any new archive command should:
  - avoid shell string interpolation;
  - pass arguments through `Process.arguments`;
  - preserve paths with spaces;
  - report command stderr clearly through `ArchiveError`.

## Localization

When adding UI text, update all supported languages:

- `en`
- `zh-Hans`
- `zh-Hant`
- `ja`
- `th`

Validate strings before submitting:

```bash
plutil -lint SimpleZip/SimpleZip/*.lproj/Localizable.strings SimpleZip/Info.plist
```

## Before Sending a Change

Run:

```bash
plutil -lint SimpleZip/SimpleZip/*.lproj/Localizable.strings SimpleZip/Info.plist

/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild \
  -project SimpleZip/SimpleZip.xcodeproj \
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
