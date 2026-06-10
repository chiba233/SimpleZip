**English** | [中文指南](./GUIDE.zh-CN.md)

# SimpleZip

![macOS](https://img.shields.io/badge/macOS-13.0%2B-000000?logo=apple&logoColor=white)
![Swift](https://img.shields.io/badge/Swift-SwiftUI-F05138?logo=swift&logoColor=white)
![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)

**A native macOS archive manager that feels like Finder.** Open archives like
folders, peek at files inside without unpacking, make ZIPs (and 7z / RAR / TAR /
DMG / gz / bz2 / xz) in a couple of clicks — and, when you need it, sign and
verify archives so the people you send them to know they're really from you.

No subscriptions, no telemetry, no clutter. Just a fast, native window.

➡️ **[Download the latest release](https://github.com/chiba233/SimpleZip/releases)** ·
[Project page](https://github.com/chiba233/SimpleZip)

---

## Why you'll like it

- 📂 **Browse an archive like a folder.** Double-click a `.zip` or `.7z` and
  walk through it as a normal file tree — no "extract everything first" step.
- 👁 **Open files without unpacking.** Double-click a document inside an archive
  and it opens in its usual app, on a temporary copy. Done with it? Nothing was
  left lying around.
- 🗜 **Make archives fast.** Select files → choose a format → done. ZIP with a
  password, a tidy 7z, a `.tar.gz` for a colleague — all from one dialog.
- 🖐 **Drag straight to Finder.** Drag a file out of an archive onto your
  Desktop; it's extracted only when you drop it.
- 🔄 **The list keeps itself fresh.** Add or remove files in Finder and
  SimpleZip's view updates on its own — no manual refresh, and your selection
  stays put.
- 🙈 **Hidden files, out of your way.** Show hidden files when you need them;
  they're tucked into a collapsible group instead of cluttering the list.
- 🔤 **Group, resize, rename.** Group a folder by kind or date, pick a
  comfortable row size, and rename files right in the list (select + Return).
- 🔐 **Sign & verify (optional).** Wrap an archive into a single signed `.siz`
  file so its signature travels with it, or sign a folder's contents in place
  with a `.szs` manifest. Encrypt to specific people and/or a password.
- 🍎 **Finder integration.** Right-click any file in Finder to hash it or zip it
  up, without even opening the main window.
- 🌍 **Speaks your language.** English, 简体中文, 繁體中文, 日本語, 한국어,
  Русский, Deutsch, Français, Español, ไทย.

## Get started in a minute

1. **Download** the latest DMG from
   [Releases](https://github.com/chiba233/SimpleZip/releases) and drag
   **SimpleZip** into your Applications folder.
2. **First open:** right-click the app → **Open** (SimpleZip is ad-hoc signed,
   so macOS asks for confirmation the first time — see *Good to know* below).
3. A short **Welcome Assistant** walks you through a few preferences and checks
   that the archive engine is ready. You can skip anything and change it later.

That's it — drag an archive onto the window, or open one with **File → Open**.

## What it can open and make

| Format | Browse | Extract | Create | Notes |
|---|:---:|:---:|:---:|---|
| ZIP | ✓ | ✓ | ✓ | Optional AES-256 password |
| 7z | ✓ | ✓ | ✓ | Strong compression |
| RAR | ✓ | ✓ | ✓\* | Opening always works; *creating* needs RARLAB's `rar` (see below) |
| TAR | ✓ | ✓ | ✓ | |
| gz / bz2 / xz | ✓ | ✓ | ✓ | Single-file compression |
| tgz / tar.gz | ✓ | ✓ | ✓ | |
| DMG | ✓ | ✓ | ✓ | Apple disk images (mounted read-only when browsing) |
| XIP | ✓ | ✓ | — | Apple-signed archives (Xcode etc.) — extraction goes through Apple's own `xip` tool, which verifies the signature |
| `.siz` | ✓ | ✓ | ✓ | Signed container — an archive with its signature attached |
| `.szs` | ✓ | — | ✓ | Signed manifest — signs files *in place* (not an archive) |
| Split sets (`.001`, `.z01`, `.r00`, `partN.rar`) | ✓ | ✓ | — | Just open the first piece |

## Signing, in plain terms

Most people never need this — but if you share files and want recipients to be
sure they came from you and weren't tampered with, SimpleZip has two options
built on standard GPG/OpenPGP:

- **`.siz` — a signed archive in one file.** Your archive plus its signature,
  bundled together. The recipient opens it and immediately sees **who signed it**
  and **whether the signature checks out**. You can also encrypt the contents to
  one or more people's public keys and/or a shared password.
- **`.szs` — sign files where they sit.** Signs a folder's contents without
  packing them up: a small signature file travels alongside, and SimpleZip can
  later confirm every file still matches. Right-click a selection →
  **Create Signed Manifest…**.

SimpleZip keeps any keys you create for it in its own private keyring, separate
from your system `~/.gnupg`, and never stores your passphrase — the standard
macOS passphrase prompt handles that. The full cryptographic design and threat
model live in **[SECURITY.md](./SECURITY.md)**.

> Using signing requires GPG. SimpleZip's GPG settings pane shows a one-line
> `brew install gnupg pinentry-mac` when it's missing, and runs a live health
> check so you know everything's wired up.

## Your data stays yours

- **Nothing is uploaded.** No accounts, no analytics, no network calls except
  the optional "check for updates".
- **Extraction never silently overwrites.** Name clashes ask you what to do
  (replace, keep both, skip — or *replace only if the contents differ*).
- **Untrusted archives are treated as untrusted.** Suspicious paths, symlinks,
  and executable/active content each prompt before they can touch your disk —
  and you can set any of them to **always block** on a shared machine.
- **Saved passwords live in the macOS Keychain**, and revealing one in the open
  requires Touch ID / your login password.

## Good to know

- SimpleZip is **ad-hoc signed** (a single-maintainer project, not yet notarized
  with a paid Developer ID). The first launch needs right-click → **Open**;
  after that it opens normally. Developer ID signing is on the roadmap.
- It is **not sandboxed** on purpose — a file manager needs to mount disk
  images, run the archive engine, and accept drag-and-drop across your disk.
- The official 7-Zip engine is **bundled** — ZIP/7z/TAR/etc. work out of the
  box with nothing else to install. GPG and RAR-creation are optional add-ons.

## Settings at a glance

- **General** — startup location, language, preset password, re-run the welcome
  assistant, back up / restore your preferences.
- **Compression / Archive** — engine choices, what to do on overwrite,
  Finder auto-extract, and the safety prompts above.
- **Browser** — show hidden files (and what counts as hidden), symlinks.
- **View** — list size (compact / standard / comfortable), which columns show,
  and optional grouping defaults.
- **File Associations** — make SimpleZip the default opener for archive types.
- **GPG** — turn signing on, manage keys, pick a default signing key.
- **Health** — a quick "is everything working?" dashboard with one-click
  *Copy Diagnostics*.

## Found a bug? Have an idea?

Please [open an issue](https://github.com/chiba233/SimpleZip/issues/new/choose) —
there are quick templates for bug reports and feature requests. The in-app
**Help → Report a Bug…** takes you straight there. For anything
security-related, see [SECURITY.md](./SECURITY.md) first.

---

## For developers

<details>
<summary>Build, test, and contribute</summary>

**Build:**

```bash
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild \
  -project SimpleZip.xcodeproj -scheme SimpleZip -configuration Debug build
```

Or open `SimpleZip.xcodeproj` and run the `SimpleZip` scheme.

**Test** (the pure-logic core lives in a SwiftPM package, `SimpleZipCoreTests` —
command construction, archive parsers, split-volume normalization, path
safety, `.siz` wrap/unwrap, etc.):

```bash
/usr/bin/xcrun swift test \
  --scratch-path /private/tmp/SimpleZipSwiftPM \
  -Xswiftc -module-cache-path -Xswiftc /private/tmp/SimpleZipSwiftPM/ModuleCache
```

**Optional backends from a checkout:**

```bash
brew install sevenzip                 # system 7-Zip (a copy is also bundled)
brew install gnupg pinentry-mac       # GPG signing / verification
./scripts/install_rar_backend.sh      # RARLAB rar, for creating .rar (not redistributable)
```

**More docs:** [Architecture](./docs/ARCHITECTURE.md) ·
[Contributing](./CONTRIBUTING.md) · [Release checklist](./docs/release-checklist.md) ·
[Bundled tools](./SimpleZip/Tools/README.md)

</details>

## Documentation

- [中文指南 (Chinese Guide)](./GUIDE.zh-CN.md)
- [Changelog](./CHANGELOG.md) · [中文更新日志](./CHANGELOG.zh-CN.md)
- [Security Policy](./SECURITY.md) · [中文安全策略](./SECURITY.zh-CN.md)

## License

MIT — see [LICENSE](./LICENSE). SimpleZip is independent, single-maintainer
software and bundles the official 7-Zip (`7zz`) binary; see
[bundled tools notes](./SimpleZip/Tools/README.md) for licensing details.
