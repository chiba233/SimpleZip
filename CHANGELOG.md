**English** | [中文](./CHANGELOG.zh-CN.md)

# Changelog

## Unreleased

- **Archive browsing**
  - Archive directories are now presented as real navigable folders instead of flat path rows.
  - Synthetic directory nodes are generated when an archive does not explicitly store directory entries.
  - Double-click and context menu opening are supported inside archive folders.
- **Extraction**
  - Extraction now stages files in a temporary directory before merging, so existing destination files always go through SimpleZip's conflict dialog instead of being overwritten by the backend.
  - Whole-archive and selected-entry extraction now support an optional password field.
  - Long-running extraction now reports progress and the current file when the backend emits progress output.
  - Selected archive extraction now defaults to the archive's containing folder and only changes destination when requested.
  - Selected archive extraction supports keeping folder structure or flattening files into the target folder.
  - ZIP selected-entry extraction uses macOS `tar` path listing/extraction to avoid `filename not matched` mismatches from `unzip`.
  - Directory selection expands to child entries before extraction.
  - Extraction merge now honors the default overwrite preference when destination files already exist.
  - Passworded archive operations now avoid passing passwords on the command line.
- **Archive creation**
  - Long-running archive creation now reports progress and the current file when the backend emits progress output.
  - Added a creation options sheet.
  - Added an archive file name field so the output name can be edited without opening the save panel.
  - ZIP and 7z creation are selectable.
  - Added compression level selection.
  - Added optional password input.
  - Added `.DS_Store`, dotfile, and custom exclude rules.
  - Archive creation now counts files before starting, shows a loading indicator during counting, and switches to determinate progress once the total is known.
  - Long-running archive commands can now be cancelled from the status bar.
  - Dotfile exclusion now explains that files like `.env`, `.gitignore`, and `.npmrc` are also skipped.
- **Reliability**
  - Archive table sorting now uses raw size and modified-date values instead of sorting localized display text.
  - Stale archive and tag loading tasks are now cancelled before newer results update the UI.
  - Drag-and-drop URL collection and external file open queuing are now synchronized to avoid callback races.
  - Added service-layer regression tests for archive list parsing, exclude pattern generation, and selected-entry expansion.
- **File browser**
  - Sidebar now includes Finder-like Favorites, Frequently Used folders, Tags, and pinned paths.
  - Tagged files can be opened as an in-app virtual file list backed by Spotlight search.
  - File deletion now asks for confirmation and moves items to the macOS Trash.
  - Paste conflicts now offer Replace, Keep Both, Skip, and Replace if Hash Differs.
  - File and archive tables now support header sorting and column reordering.
  - Header context menus can jump directly to column settings.
  - The location bar is editable and falls back to the deepest valid folder or archive path.
  - Replaced SwiftUI table usage with AppKit-backed tables for macOS 13 compatibility and better multi-select behavior.
  - Added native mouse drag multi-selection.
  - Added file copy, cut, paste, move, delete, reveal, and drag-out behavior.
  - Replace-if-hash-diff now shows hash comparison progress and a result dialog with both SHA256 values.
- **File associations**
  - Settings now show a per-extension association list.
  - Each supported archive extension can be set as default individually.
  - Current default app is displayed per format.
- **Hashing**
  - Added CRC32, MD5, SHA1, SHA256, and SHA512 reports.
- **Menus**
  - Added functional macOS File menu actions for opening, creating, extracting, testing, hashing, revealing, refreshing, and navigating.
  - Added Edit menu commands that use file operations when the file table is active and fall back to native text editing actions elsewhere.
- **Settings**
  - Settings are now separated into General, Archive, Browser, File Associations, and Columns tabs.
  - Added language selection.
  - Added 7-Zip backend selection for Automatic, Bundled, and System binaries with version display.
  - Bundled backend display now clearly labels whether the resolved binary is bundled or system-provided.
  - 7-Zip backend detection now searches bundled paths, common Homebrew paths, Homebrew `opt` and `Cellar` folders, and PATH.
  - Added default startup folder, extract destination, overwrite behavior, hidden-file visibility, and column visibility settings.
- **7-Zip backend**
  - Bundled official 7-Zip 26.01 universal macOS `7zz` binary with `x86_64` and `arm64` slices.
  - Added bundled 7-Zip license and readme files to app resources.
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
