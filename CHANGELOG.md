**English** | [中文](./CHANGELOG.zh-CN.md)

# Changelog

## Unreleased

- **Archive browsing**
  - Archive directories are now presented as real navigable folders instead of flat path rows.
  - Synthetic directory nodes are generated when an archive does not explicitly store directory entries.
  - Double-click and context menu opening are supported inside archive folders.
- **Extraction**
  - Selected archive extraction supports keeping folder structure or flattening files into the target folder.
  - ZIP selected-entry extraction uses macOS `tar` path listing/extraction to avoid `filename not matched` mismatches from `unzip`.
  - Directory selection expands to child entries before extraction.
- **Archive creation**
  - Added a creation options sheet.
  - ZIP and 7z creation are selectable.
  - Added compression level selection.
  - Added optional password input.
  - Added `.DS_Store`, dotfile, and custom exclude rules.
- **File browser**
  - Replaced SwiftUI table usage with AppKit-backed tables for macOS 13 compatibility and better multi-select behavior.
  - Added native mouse drag multi-selection.
  - Added file copy, cut, paste, move, delete, reveal, and drag-out behavior.
- **File associations**
  - Settings now show a per-extension association list.
  - Each supported archive extension can be set as default individually.
  - Current default app is displayed per format.
- **Hashing**
  - Added CRC32, MD5, SHA1, SHA256, and SHA512 reports.
- **Menus**
  - Added functional macOS File menu actions for opening, creating, extracting, testing, hashing, revealing, refreshing, and navigating.
  - Added Edit menu style file management commands.
- **Settings**
  - Added language selection.
  - Added default startup folder, extract destination, overwrite behavior, hidden-file visibility, and column visibility settings.
- **Localization**
  - Added English, Simplified Chinese, Traditional Chinese, Japanese, and Thai strings.
- **Docs**
  - Added README, Chinese guide, changelog, contribution guide, and license files.

## 0.1.0

- Initial SimpleZip prototype:
  - macOS SwiftUI shell;
  - folder browsing;
  - basic ZIP open/create/extract flow;
  - About panel and project page metadata.
