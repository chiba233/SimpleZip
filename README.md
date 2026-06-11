**English** | [中文指南](./GUIDE.zh-CN.md)

# SimpleZip

![macOS](https://img.shields.io/badge/macOS-13.0%2B-000000?logo=apple&logoColor=white)
![Swift](https://img.shields.io/badge/Swift-SwiftUI-F05138?logo=swift&logoColor=white)
![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)

**A native macOS archive manager that feels like Finder.** Open archives like
folders, peek at — or *edit* — files inside without unpacking, make and convert
ZIP / 7z / RAR / TAR / DMG / gz / bz2 / xz in a couple of clicks — and open
`tar.zst`, ISO, CAB, CPIO and installer PKGs read-only. When you need it, sign
and verify archives so the people you send them to know they're really from you.

No subscriptions, no telemetry, no clutter. Just a fast, native window — built
on the official 7-Zip engine, which ships inside the app.

➡️ **[Download the latest release](https://github.com/chiba233/SimpleZip/releases)** ·
[Project page](https://github.com/chiba233/SimpleZip)

---

## 📸 A look inside

| | |
|---|---|
| ![Browsing files](https://raw.githubusercontent.com/chiba233/SimpleZip/main/demo/mainView.png) | ![Inside an archive](https://raw.githubusercontent.com/chiba233/SimpleZip/main/demo/archiveView.png) |
| **Browse like Finder** — your files, a modern native window. | **Open an archive like a folder** — walk the tree, no unpacking. |
| ![Creating an archive](https://raw.githubusercontent.com/chiba233/SimpleZip/main/demo/addArchiveView.png) | ![Extracting](https://raw.githubusercontent.com/chiba233/SimpleZip/main/demo/unzipView.png) |
| **Create** — format, password, templates, a live dry-run. | **Extract** — pre-flight summary before anything touches disk. |
| ![Activity Center](https://raw.githubusercontent.com/chiba233/SimpleZip/main/demo/ActivityView.png) | ![Checksums](https://raw.githubusercontent.com/chiba233/SimpleZip/main/demo/hashView.png) |
| **Activity Center** — every operation, with live progress. | **Checksums** — hash files in a click, copy results. |

![Settings](https://raw.githubusercontent.com/chiba233/SimpleZip/main/demo/SettingView.png)

> *Settings — everything in one tidy, native window.*

---

## ✨ Why you'll like it

- 📂 **Browse an archive like a folder.** Double-click a `.zip` or `.7z` and
  walk through it as a normal file tree — no "extract everything first" step.
  Folders in the local file browser expand in place too, Finder list-view style.
- 👁 **Open files without unpacking.** Double-click a document inside an archive
  and it opens in its usual app, on a temporary copy. Done with it? Nothing was
  left lying around.
- ✍️ **Edit inside an archive.** Open a file from a ZIP/7z, edit it, and the
  change is written back into the archive — no unpack/repack dance. You can also
  add, rename, or delete entries, or drag files straight into an open archive.
- 🗜 **Make, convert, split.** Select files → choose a format → done (ZIP with a
  password, a tidy 7z, a `.tar.gz`). Convert an archive to another format, or
  split a large file into volumes and recombine them later — byte for byte.
- 🖐 **Drag straight to Finder.** Drag a file out of an archive onto your
  Desktop; it's extracted only when you drop it.
- ↩️ **Undo / redo.** Move, rename, copy, duplicate, delete, split, combine,
  convert, even permission changes — ⌘Z takes them back (safely; it never
  silently clobbers your data).
- 🔍 **Search, filter, compare.** Search with power tokens (`*.swift size:>1MB
  encrypted:true modified:<7d regex:…`), save your favorite filters, and diff two
  archives — or a folder against an archive — exporting the result as JSON / CSV /
  Markdown.
- 🔄 **The list keeps itself fresh.** Add or remove files in Finder and
  SimpleZip's view updates on its own — no manual refresh, and your selection
  stays put.
- 🙈 **Hidden files, out of your way.** Show hidden files when you need them;
  they're tucked into a collapsible group instead of cluttering the list.
- 🔤 **Group, resize, rename, chmod.** Group a folder by kind or date, pick a
  comfortable row size, rename in the list (select + Return), and view or change
  Unix permissions / owner from the right-click menu.
- 🔐 **Sign & verify (optional).** Wrap an archive into a single signed `.siz`
  file so its signature travels with it, or sign a folder's contents in place
  with a `.szs` manifest. Encrypt to specific people and/or a password, and hand
  someone a self-explaining **Secure Bundle**.
- 🍎 **Finder integration.** Right-click any file in Finder to hash it or zip it
  up, without even opening the main window.
- 🌍 **Speaks your language.** English, 简体中文, 繁體中文, 日本語, 한국어,
  Русский, Deutsch, Français, Español, ไทย.

### 🧰 Power tools, when you reach for them

- **Convert formats** — re-pack a `.rar` as `.7z`, a `.zip` as an encrypted
  `.siz`, in one step (right-click → Convert…).
- **Split & combine** — break a large file into `partN` volumes and rejoin them,
  byte-for-byte, matching 7-Zip's Split / Combine.
- **Archive comments** — read *and edit* the whole-archive comment of a ZIP, right
  in the browser.
- **Templates & presets** — start from a ready-made recipe (GitHub Release ZIP,
  max-compression 7z, encrypted delivery, source tarball without `node_modules`…)
  or save your own named default.
- **Pre-flight checks** — a creation dry-run (file count, size, what gets excluded),
  a pre-extraction summary with a disk-space warning, and a one-click
  **Release Check** (integrity test, suspicious paths, junk, empty dirs, SHA-256)
  before you ship a build.
- **Reproducible archives** — a switch in the create dialog makes the same input
  produce a byte-identical ZIP/7z (same SHA-256) on every run. Made for GitHub
  releases and verifiable builds; pairs with **Export SHA256SUMS**.
- **Checksum files** — generate GNU-compatible `SHA256SUMS` for a selection, and
  verify `SHA256SUMS` / `.sha256` / `.md5` / `.sfv` files someone sent you, with
  per-file pass/fail in the Activity Center.
- **Verified writes, recoverable failures** — every archive rewrite is tested
  *before* it atomically replaces the original, and a rewrite stopped at the last
  gate (external change, failed verification) parks its work copy in a Recovery
  area instead of burning it. Big operations check disk space up front.
- **Session passwords** — an archive's password is asked once per session: tests,
  batch jobs and Finder auto-extract silently reuse passwords you've already
  proven (memory only — forgotten the moment the app quits; only the optional
  preset password persists, in the macOS Keychain).
- **Long tasks are protected** — running tasks hold off idle sleep, and quitting
  with work in flight asks first (or quits by itself when the last task ends).
- **Batch tools** — test, convert, or rename many entries at once, find duplicate
  files, and clean macOS metadata junk (`.DS_Store` / `__MACOSX`).
- **Split-set awareness** — `.001 / .002 / partN.rar` recognized as a group, with
  missing-volume warnings before you combine.
- **Permissions & owner** — a Unix-permissions column and right-click chmod /
  chown for local files.
- **Benchmark** — measure the 7-Zip engine's compression / decompression speed on
  your Mac.
- **Activity Center** — every operation, re-runnable, with copyable equivalent
  commands and an exportable diagnostics bundle.
- **Tabs & multiple windows** — open archives and folders in native window tabs.
- **Quick Look, Get Info, Open With** — the Finder essentials, right in the list.

## 🚀 Get started in a minute

1. **Download** the latest DMG from
   [Releases](https://github.com/chiba233/SimpleZip/releases) and drag
   **SimpleZip** into your Applications folder.
2. **First open:** right-click the app → **Open** (SimpleZip is ad-hoc signed,
   so macOS asks for confirmation the first time — see *Good to know* below).
3. A short **Welcome Assistant** walks you through a few preferences and checks
   that the archive engine is ready. You can skip anything and change it later.

That's it — drag an archive onto the window, or open one with **File → Open**.

## 🗂 What it can open and make

| Format | Open | Extract | Create | Notes |
|---|:---:|:---:|:---:|---|
| ZIP | ✓ | ✓ | ✓ | Optional AES-256 password |
| 7z | ✓ | ✓ | ✓ | Strong compression |
| RAR | ✓ | ✓ | ✓\* | Opening always works; *creating* needs RARLAB's `rar` (an optional add-on) |
| TAR | ✓ | ✓ | ✓ | |
| gz / bz2 / xz | ✓ | ✓ | ✓ | Single-file compression |
| tgz / tar.gz | ✓ | ✓ | ✓ | Opens straight into the inner tar |
| zst / tar.zst | ✓ | ✓ | — | Zstandard, read-only — the bundled 7-Zip decodes it but has no zstd encoder |
| ISO / CAB / CPIO / XAR / PKG | ✓ | ✓ | — | Read-only — browse and extract disk images, cabinets and installer packages |
| DMG | ✓ | ✓ | ✓ | Apple disk images (mounted read-only when browsing) |
| XIP | ✓ | ✓ | — | Apple-signed archives (Xcode etc.) — extraction goes through Apple's own `xip` tool, which verifies the signature |
| `.gpg` / `.pgp` / `.asc` / `.key` | ✓ | ✓ | ✓ | GPG-encrypted files decrypt and open in place; key material offers to import into a keyring. "Create" = right-click → Encrypt to `.gpg` |
| `.siz` | ✓ | ✓ | ✓ | Signed container — an archive with its signature attached |
| `.szs` | ✓ (verify) | in place | ✓ | Signed manifest — *verifies* a folder's files where they sit and browses them as a virtual folder; nothing unpacks, because nothing was packed |
| Split sets (`.001`, `.z01`, `.r00`, `partN.rar`) | ✓ | ✓ | — | Just open the first piece |

> Anything SimpleZip can't modify in place (tar family, RAR, the read-only family
> above) wears a **Read-Only** badge in the status bar that explains why — and
> conversion to ZIP/7z is one right-click away.

## 🔏 Signing, in plain terms

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
- **Secure Bundle** — a `.siz` you hand to someone carries human-readable,
  tamper-proof recipient instructions, so the person on the other end knows what
  they received and how to verify it.

You manage keys in **Settings → GPG**: a five-group keyring (your local secret
keys, your smartcard / OpenPGP-token keys, and others' public keys), per-key
trust levels, add-a-subkey, and optional hardware-token support. SimpleZip keeps
any keys it creates in its own private keyring, separate from your system
`~/.gnupg`, and never stores your passphrase — the standard macOS prompt handles
that. The full cryptographic design and threat model live in
**[SECURITY.md](./SECURITY.md)**.

> Using signing requires GPG. SimpleZip's GPG settings pane shows a one-line
> `brew install gnupg pinentry-mac` when it's missing, and runs a live health
> check so you know everything's wired up.

## 🛡 Your data stays yours
<a id="safety-model"></a>

- **Nothing is uploaded.** No accounts, no analytics, and the archive workflows
  never touch the network. The only network activity is what you explicitly ask
  for: the optional update check (Sparkle), GPG key-server search / publish from
  the key-server section (performed by GnuPG's own `dirmngr`, and publishing a
  key always confirms first), and the optional RAR backend installer you run
  yourself.
- **Nothing is silently overwritten.** Extracting, pasting, dropping, or creating
  an archive over an existing name all use the same conflict dialog — replace,
  keep both, merge (Finder-style) or replace the whole folder (tar-style), skip,
  or *replace only if the contents differ*. Overwrites write to a temp file and
  atomically swap on success, so a failed operation can't lose both copies.
- **Editing inside an archive is non-destructive.** Saving a change back into a
  ZIP/7z stages a copy and atomically replaces the original; if anything fails,
  your archive is left byte-for-byte intact.
- **Untrusted archives are treated as untrusted.** Suspicious paths, symlinks,
  hardlinks, and executable/active content each prompt before they can touch your
  disk — and you can set any of them to **always block** on a shared machine.
- **Temporary extractions live in a per-session encrypted scratch volume** and are
  cleaned up the moment you close the archive.
- **Saved passwords live in the macOS Keychain**, and revealing one in the open
  requires Touch ID / your login password. Session-remembered archive passwords
  are memory-only and vanish when the app quits. SimpleZip never stores GPG
  passphrases.
- **Rewrites are verified before they land.** An edited archive is integrity-tested
  on its work copy *before* the atomic swap; if the original changed externally in
  the meantime, the write stops and your finished work copy is preserved in a
  visible Recovery area.

> The full threat model, the `.siz` / `.szs` cryptographic design, the encrypted
> scratch volume, and the Sparkle update-signature scheme are documented in
> **[SECURITY.md](./SECURITY.md)**.

## 💡 Good to know

- SimpleZip is **ad-hoc signed** (a single-maintainer project, not yet notarized
  with a paid Developer ID). The first launch needs right-click → **Open**;
  after that it opens normally. Developer ID signing is on the roadmap.
- It is **not sandboxed** on purpose — a file manager needs to mount disk
  images, run the archive engine, and accept drag-and-drop across your disk.
- The official 7-Zip engine is **bundled** — ZIP/7z/TAR/etc. work out of the
  box with nothing else to install. GPG and RAR-creation are optional add-ons.

## ⚙️ Settings at a glance

- **General** — startup location, language, preset password, re-run the welcome
  assistant, back up / restore your preferences.
- **Compression / Archive** — engine choices, what to do on overwrite,
  Finder auto-extract, and the safety prompts above.
- **Browser** — show hidden files (and what counts as hidden), symlinks.
- **View** — list size (compact / standard / comfortable), which columns show,
  and optional grouping defaults.
- **File Associations** — make SimpleZip the default opener for archive types.
- **Software Update** — check for new versions and read the release notes in-app.
- **GPG** — turn signing on, manage keys, pick a default signing key.
- **Health** — a quick "is everything working?" dashboard with one-click
  *Copy Diagnostics*.

## 🐞 Found a bug? Have an idea?

Please [open an issue](https://github.com/chiba233/SimpleZip/issues/new/choose) —
there are quick templates for bug reports and feature requests. The in-app
**Help → Report a Bug…** takes you straight there. For anything
security-related, see [SECURITY.md](./SECURITY.md) first.

---

## 📚 More

- [中文指南 (Chinese Guide)](./GUIDE.zh-CN.md)
- [What's new (Changelog)](./CHANGELOG.md) · [中文更新日志](./CHANGELOG.zh-CN.md)
- [Security & signing details](./SECURITY.md) · [中文安全策略](./SECURITY.zh-CN.md)

## License

MIT — see [LICENSE](./LICENSE). SimpleZip is independent, single-maintainer
software and bundles the official 7-Zip (`7zz`) binary; see
[bundled tools notes](./SimpleZip/Tools/README.md) for licensing details.
