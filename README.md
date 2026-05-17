**English** | [中文指南](./GUIDE.zh-CN.md)

# SimpleZip

![macOS](https://img.shields.io/badge/macOS-13.0%2B-000000?logo=apple&logoColor=white)
![Swift](https://img.shields.io/badge/Swift-SwiftUI-F05138?logo=swift&logoColor=white)
![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)

SimpleZip is a native macOS archive manager inspired by 7-Zip and NanaZip. It is built around a Finder-like file browser,
real archive folder navigation, direct open-from-archive workflows, drag-and-drop extraction, archive creation, hashing,
file associations, and a bundled 7-Zip backend.

Project page: [github.com/chiba233/SimpleZip](https://github.com/chiba233/SimpleZip)

## Highlights

- Native SwiftUI + AppKit macOS interface with multi-select, sortable/reorderable columns, context menus, command menus,
  toolbar actions, and a location bar.
- Browse archives as real folders instead of flat path lists. Missing directory entries are synthesized so nested archive
  paths still feel navigable.
- Double-click files inside archives to temporarily extract and open them with the default macOS app.
- Drag archive entries out to Finder or other file destinations. SimpleZip extracts the promised files at the drop target.
- Extract whole archives or selected entries, with options to preserve folder structure or flatten selected files.
- Create ZIP, 7z, RAR, TAR, GZip, TAR.GZ, BZip2, and XZ archives with format-aware options.
- Built-in file manager actions: open, copy, cut, paste, move, delete to Trash, reveal in Finder, drag local files, and
  accept external file drops.
- Hash selected files with CRC32, MD5, SHA1, SHA256, and SHA512.
- Manage default app associations per archive extension, including RAR, DMG, and common split-volume extensions.
- Configure 7-Zip and RAR backends from Settings, with resolved path and version display.
- Localized UI in English, Spanish, French, German, Korean, Russian, Simplified Chinese, Traditional Chinese, Japanese,
  and Thai.

## Supported Formats

| Format | Browse | Extract | Create | Backend / Notes |
| --- | --- | --- | --- | --- |
| `.zip` | Yes | Yes | Yes | Uses 7-Zip when needed; can fall back to macOS ZIP tools for simple creation |
| `.7z` | Yes | Yes | Yes | Uses bundled or system `7zz` / `7z` |
| `.rar` | Yes | Yes | Yes | Browse/extract through 7-Zip; create through RARLAB `rar` |
| `.tar` | Yes | Yes | Yes | Create through macOS `tar`; browse/extract through 7-Zip |
| `.gz` | Yes | Yes | Yes | Single-file creation through 7-Zip |
| `.tgz` / `.tar.gz` | Yes | Yes | Yes | Create through macOS `tar`; browse/extract through 7-Zip |
| `.bz2` | Yes | Yes | Yes | Single-file creation through 7-Zip |
| `.xz` | Yes | Yes | Yes | Single-file creation through 7-Zip |
| `.dmg` | Yes | Yes | No | Mounted read-only with `hdiutil`; extraction copies mounted contents |
| `.001`, `.002`, `.z01`, `.r00`, `part02.rar` | Yes | Yes | No | Normalized to the first volume automatically |

## Archive Workflows

### Browse and Open

Open a supported archive from the toolbar, File menu, Finder, drag-and-drop, or by double-clicking it in the file browser.
Archive folders appear as folders, so paths like `App.app/Contents/Info.plist` become a navigable folder tree.

Inside an archive:

- double-click a folder to enter it;
- double-click a file to extract it to a temporary location and open it with the default macOS app;
- drag files or folders out to Finder to extract them at the drop location;
- use the context menu for Open, Extract Selected, Extract Whole Archive, Test, Hash, and Reveal in Finder.

Package-style directories such as `.app` and `.pkg` are treated as openable items when possible instead of only as plain
folders.

### Extract

Whole-archive extraction and selected-entry extraction share the same options form:

- destination folder;
- optional password;
- Show Details for live backend output;
- overwrite behavior through Settings;
- selected-entry path mode: preserve folder structure or flatten files into the destination.

Extraction stages files in a temporary directory first, then merges them into the destination. That gives SimpleZip a
chance to show conflict handling instead of letting the backend overwrite files silently.

### Create

Select files or folders in the file browser and choose Add. The creation sheet supports:

- archive file name editing;
- format selection: ZIP, 7z, RAR, TAR, GZip, TAR.GZ, BZip2, XZ;
- compression level;
- optional passwords for ZIP, 7z, and RAR;
- `.DS_Store` exclusion;
- dotfile exclusion, including files such as `.env`, `.gitignore`, and `.npmrc`;
- custom exclude rules;
- split-volume output for ZIP, 7z, and RAR;
- advanced 7-Zip options such as dictionary size, word size, solid blocks, path mode, symlink/hard-link storage,
  shared-file compression, raw parameters, and delete-after-compression.

GZip, BZip2, and XZ are single-file formats. SimpleZip blocks invalid multi-file or folder selections before launching
the backend.

## Backends

### 7-Zip

SimpleZip includes the official 7-Zip 26.01 universal macOS `7zz` binary at:

```text
SimpleZip/Tools/7zz
```

It contains both `x86_64` and `arm64` slices and is copied into development app bundles. Settings can use Automatic,
Bundled, or System mode. Automatic searches bundled app resources first, then common Homebrew locations and `PATH`.

You can also install a system 7-Zip:

```bash
brew install sevenzip
```

### RAR

RAR creation requires the official RARLAB `rar` command-line tool. SimpleZip can search bundled, app-bundled, system,
Homebrew, and `PATH` locations. For local development or local packaging, run:

```bash
./scripts/install_rar_backend.sh
```

The script downloads the official RARLAB macOS ARM and x64 command-line packages, creates a universal local
`SimpleZip/Tools/rar`, and keeps it ignored by git.

RARLAB `rar` is proprietary/shareware. Do not redistribute a public app package containing that local backend unless you
have RARLAB redistribution permission.

## File Browser

SimpleZip's main view is also a practical file manager:

- Finder-like sidebar with common locations, frequently used folders, tags, and pinned paths;
- sortable and reorderable file columns, including Kind, Application, Last Opened, Date Added, Modified, Created, and
  Size;
- open, add to archive, extract here, test, hash, copy, cut, paste, move, delete to Trash, and reveal actions;
- drag local files to folders inside the file table to move them;
- drop external files into the current folder to copy them;
- conflict handling for paste/extract, including Replace, Keep Both, Skip, and Replace if Hash Differs.

## Settings

Settings are split into General, Archive, Browser, File Associations, and Columns:

- startup location and remembering the last opened folder;
- default overwrite behavior: Ask, Overwrite, or Skip;
- hidden-file visibility;
- 7-Zip backend mode and version;
- RAR backend mode, resolved path, and version;
- per-extension default app management;
- visible file and archive columns;
- UI language.

Language changes fully apply after restarting SimpleZip.

## Build

```bash
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild \
  -project SimpleZip.xcodeproj \
  -scheme SimpleZip \
  -configuration Debug build
```

Or open:

```text
SimpleZip.xcodeproj
```

Then run the `SimpleZip` scheme in Xcode.

## Documentation

- [Chinese Guide](./GUIDE.zh-CN.md)
- [Changelog](./CHANGELOG.md)
- [中文更新日志](./CHANGELOG.zh-CN.md)
- [Contributing](./CONTRIBUTING.md)
- [Bundled Tools Notes](./SimpleZip/Tools/README.md)

## Status

SimpleZip is still early, but it is no longer a minimal ZIP shell. The current goal is to become a comfortable native
macOS archive client first, then keep adding advanced backend controls without turning the interface into a wall of
switches.

## License

MIT. See [LICENSE](./LICENSE).
