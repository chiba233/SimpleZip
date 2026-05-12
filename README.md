**English** | [中文](./GUIDE.zh-CN.md)

# SimpleZip

![macOS](https://img.shields.io/badge/macOS-13.0%2B-000000?logo=apple&logoColor=white)
![Swift](https://img.shields.io/badge/Swift-SwiftUI-F05138?logo=swift&logoColor=white)
![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)

A friendlier 7zz GUI client for macOS.

SimpleZip is a macOS archive manager inspired by 7-Zip and NanaZip. It aims to make archive browsing, extraction,
creation, hashing, and file association management feel native on macOS while keeping the power of the bundled `7zz`
backend close at hand.

Project page: [github.com/chiba233/SimpleZip](https://github.com/chiba233/SimpleZip)

## What It Is

- A native macOS archive browser built with SwiftUI and AppKit table views.
- A GUI for everyday ZIP work using macOS built-in tools.
- A GUI for 7z/tar/gz/tgz/bz2/xz workflows through the bundled or system `7zz` / `7z` backend.
- A file hash utility for CRC32, MD5, SHA1, SHA256, and SHA512.
- A practical Finder-like file browser with copy, cut, paste, move, delete, reveal, drag, and multi-select.

## Current Features

- Browse folders and supported archives.
- Open archive directories as real folders instead of flattening paths.
- Extract whole archives or selected archive entries.
- Choose selected-extraction mode:
  - keep folder structure;
  - extract files directly into the destination folder.
- Create ZIP or 7z archives with:
  - compression level;
  - optional password;
  - `.DS_Store` exclusion;
  - dotfile exclusion;
  - custom exclude rules.
- Calculate file hashes.
- Configure file associations per archive extension.
- Customize visible columns for folder and archive tables.
- Built-in UI language setting:
  - English;
  - Simplified Chinese;
  - Traditional Chinese;
  - Japanese;
  - Thai.

## Supported Formats

| Format | Browse | Extract | Create | Notes |
| --- | --- | --- | --- | --- |
| `.zip` | Yes | Yes | Yes | Uses macOS built-in `zip`, `unzip`, and `tar` |
| `.7z` | Yes | Yes | Yes | Requires `7zz` or `7z` |
| `.tar` | Yes | Yes | No | Requires `7zz` or `7z` in the current backend |
| `.gz` | Yes | Yes | No | Requires `7zz` or `7z` |
| `.tgz` | Yes | Yes | No | Requires `7zz` or `7z` |
| `.bz2` | Yes | Yes | No | Requires `7zz` or `7z` |
| `.xz` | Yes | Yes | No | Requires `7zz` or `7z` |

## Requirements

- macOS 13.0 or newer.
- Xcode with the macOS SDK.
- Bundled official 7-Zip CLI for `.7z` and other non-ZIP formats.
- Optional: install a system 7-Zip CLI if you prefer using Homebrew or another external binary.

SimpleZip currently includes the official 7-Zip 26.01 universal macOS `7zz` binary in `SimpleZip/Tools/7zz`.
It contains both `x86_64` and `arm64` slices, and is copied into the app bundle during development builds.

You can also use a system installation:

```bash
brew install sevenzip
```

SimpleZip can be configured to use Automatic, Bundled, or System backends. Automatic searches bundled paths first, then
common Homebrew paths:

- `Contents/Resources/7zz`
- `Contents/Resources/Tools/7zz`
- `Contents/Resources/7z`
- `Contents/Resources/Tools/7z`
- `/opt/homebrew/bin/7zz`
- `/usr/local/bin/7zz`
- `/opt/homebrew/bin/7z`
- `/usr/local/bin/7z`

## Build

```bash
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild \
  -project SimpleZip/SimpleZip.xcodeproj \
  -scheme SimpleZip \
  -configuration Debug build
```

Or open `SimpleZip/SimpleZip.xcodeproj` in Xcode and run the `SimpleZip` scheme.

## Documentation

- [Chinese Guide](./GUIDE.zh-CN.md)
- [Changelog](./CHANGELOG.md)
- [中文更新日志](./CHANGELOG.zh-CN.md)
- [Contributing](./CONTRIBUTING.md)

## Status

SimpleZip is still early. The current target is to become a comfortable macOS archive client first, then keep filling
in advanced 7-Zip options without making the interface noisy.

## License

MIT. See [LICENSE](./LICENSE).
