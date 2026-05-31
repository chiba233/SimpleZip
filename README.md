**English** | [中文指南](./GUIDE.zh-CN.md)

# SimpleZip

![macOS](https://img.shields.io/badge/macOS-13.0%2B-000000?logo=apple&logoColor=white)
![Swift](https://img.shields.io/badge/Swift-SwiftUI-F05138?logo=swift&logoColor=white)
![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)

A native macOS archive manager. Browses archives like folders, opens files
inside without manually extracting first, creates ZIP / 7z / RAR / TAR / DMG /
gzip / bzip2 / xz, hashes files, manages file associations, integrates with
Finder, and — uniquely — signs and verifies archives with GPG via the
**`.siz` signed container** format.

Project page: [github.com/chiba233/SimpleZip](https://github.com/chiba233/SimpleZip)

## Highlights

- **Folder-like archive browser.** Paths inside an archive render as a tree,
  not a flat string list. Missing intermediate directories get synthesized so
  navigation stays sensible.
- **Open without extracting.** Double-click any file inside an archive and
  macOS opens its default app on a temporary copy. DMGs inside archives mount
  read-only; `.app` / `.pkg` are treated as openable items.
- **Drag out to Finder.** SwiftUI/AppKit promised-files plumbing: the bytes
  only get extracted when you drop somewhere, not while dragging.
- **GPG signing built-in.** Archives can be wrapped into a `.siz` container
  that travels with its signature attached. The verify path uses
  `gpg --status-fd 1` for locale-stable parsing and does fingerprint strong
  comparison against the metadata's claim.
- **`.siz` v3 multi-recipient encryption.** Optional GPG-encrypt the inner
  archive to one or more recipients **and/or** a symmetric passphrase
  (`gpg --symmetric --encrypt`). Combined mode = either a recipient's private
  key **or** the password can decrypt. Passphrase rides stdin so it never
  appears in `ps`.
- **`.szs` Signed Manifests.** Sign a tree of files without bundling them
  (`gpg --clearsign` of a JSON manifest containing per-file SHA256s). Files
  stay in place; the `.szs` travels alongside. SimpleZip can browse the
  signed file set as a **virtual folder** that hides anything not in the
  manifest. Right-click any selection of files → **Create Signed Manifest…**
  to generate one.
- **GPG key management UI.** Full settings pane for creating, importing,
  exporting, signing, encrypting-style operations, expiration, passphrase
  changes, UIDs, trust levels, smartcard binding, default signing key, and
  per-archive "ask which key" mode for multi-key users. SimpleZip's
  private-only ring is isolated in its own GNUPGHOME so it never pollutes
  `~/.gnupg/`.
- **Preset password with Keychain + Touch ID.** Saved passwords live in
  `kSecAttrAccessibleAfterFirstUnlock`; revealing the plaintext requires
  `LAContext.deviceOwnerAuthentication`.
- **Finder integration.** Right-click any file or folder in Finder to hash it
  or wrap it into a new archive without launching the main window.
- **Localized.** English, Simplified Chinese, Traditional Chinese, Japanese,
  Korean, Russian, German, French, Spanish, Thai.

## Quick Start

1. Download the latest DMG from
   [Releases](https://github.com/chiba233/SimpleZip/releases) and drag
   `SimpleZip.app` into `/Applications`.
2. First launch: right-click the app → **Open** (SimpleZip is ad-hoc signed;
   Gatekeeper needs explicit consent the first time).
3. The Welcome Assistant runs on first launch and verifies backends
   (`7zz`, optionally `gpg` + `pinentry-mac`). Skip GPG if you don't need it.
4. Optional: enable GPG integration from **Settings → GPG**. Install
   `gnupg` + `pinentry-mac` if missing (the pane shows the exact
   `brew install` command).

## Supported Formats

| Format | Browse | Extract | Create | Backend / Notes |
| --- | --- | --- | --- | --- |
| `.zip` | ✓ | ✓ | ✓ | 7-Zip (preferred), fall back to system zip for simple cases |
| `.7z` | ✓ | ✓ | ✓ | Bundled or system `7zz` / `7z` |
| `.rar` | ✓ | ✓ | ✓ | Browse/extract via 7-Zip; create needs RARLAB `rar` |
| `.tar` | ✓ | ✓ | ✓ | Create via system `tar`; browse/extract via 7-Zip |
| `.gz` / `.bz2` / `.xz` | ✓ | ✓ | ✓ | Single-file streams |
| `.tgz` / `.tar.gz` | ✓ | ✓ | ✓ | Create via system `tar` |
| `.dmg` | ✓ | ✓ | ✓ | Created and mounted via macOS `hdiutil` |
| `.siz` | ✓ | ✓ | ✓ | SimpleZip GPG-signed container (tar shell) — v3 supports multi-recipient + symmetric encryption |
| `.szs` | ✓ (virtual) | — | ✓ | SimpleZip GPG-signed manifest (clearsigned JSON of per-file SHA256s) — not an archive |
| `.001` `.z01` `.r00` `partN.rar` | ✓ | ✓ | — | Auto-normalized to the first volume |

## `.siz` Signed Containers

`.siz` is SimpleZip's solution to "I want to send a signed archive and have
the signature travel with the file". A `.siz` is a tar shell containing:

- `archive.<ext>` — the inner archive, byte-for-byte unmodified (so the
  user's chosen compression + native encryption like ZIP AES-256 / 7z header
  encryption stays intact);
- `metadata.json` — schema, version, inner format, inner SHA256, signer
  claim, timestamp;
- `signature.asc` — GPG detached signature of `metadata.json` (ASCII armor).

**Signature target is `metadata.json`, not the inner archive.** This is the
crucial design choice — see [SECURITY.md](./SECURITY.md#siz-signed-container-format)
for the full threat model. Short version: signing metadata + including the
inner archive's SHA256 in metadata closes all the impersonation paths that
"sign the inner archive only" would leave open.

Verification (`SIZArchive.verify`):

1. `gpg --status-fd 1 --verify` against `metadata.json` → parses `GOODSIG /
   VALIDSIG / TRUST_*` machine-readable status (no locale-dependent string
   matching).
2. **Fingerprint strong comparison**: actual signing fingerprint from
   `VALIDSIG` must equal `metadata.signature.signerFingerprint`. Mismatch =
   `badSignature` (defense against "edit metadata, re-sign with own key").
3. **SHA256 check**: recomputed inner-archive SHA must equal
   `metadata.innerArchiveSHA256`. Mismatch = `badSignature`.
4. Status codes `EXPKEYSIG` / `REVKEYSIG` / `EXPSIG` propagate as
   "valid signature with concern" (orange UI), not blocking errors.

### v3 multi-recipient encryption (0.1.9)

`.siz` v3 adds optional encryption of the **inner** archive (the signed
metadata + verification flow stays the same). Three modes:

- **Recipients only** — `gpg --encrypt --recipient <fp> ...`. Anyone with a
  matching private key decrypts.
- **Symmetric passphrase only** — `gpg --symmetric`. Anyone with the
  password decrypts.
- **Combined** — `gpg --symmetric --encrypt --recipient ...`. Either a
  recipient's private key **or** the password decrypts.

Metadata records the recipient list (fingerprints + UIDs) as a *claim*
inside the signed metadata, plus a `hasSymmetricPassphrase` flag (the
password itself never appears in metadata). The `innerArchiveSHA256` is
computed over the **encrypted** bytes so anyone with the public manifest can
verify container integrity without a decryption key (and an attacker can't
re-encrypt with a different session key to forge a matching SHA).

Unwrap detects the `archive.<ext>.gpg` name + `encryption` field → calls
`gpg --decrypt` with the user-provided key fingerprint hint and/or
passphrase. Passphrase rides stdin (`--passphrase-fd 0`) — never visible in
`ps`. Decrypted plaintext lands in the same tempdir as the unwrap and is
cleaned up after extract finishes.

## `.szs` Signed Manifests

`.szs` solves a different problem from `.siz`: **"sign a tree of files that
stays as separate files on disk"** — release drops (app + LICENSE + README +
checksums), mirror trees, per-file integrity audits. The `.szs` is a single
GPG-clearsigned JSON manifest you ship alongside the files.

```
-----BEGIN PGP SIGNED MESSAGE-----
Hash: SHA512

{ "schema": "SimpleZip.szs", "version": 1,
  "files": [
    { "relativePath": "README.md", "size": 1234, "sha256": "abc..." },
    ...
  ],
  ... }
-----BEGIN PGP SIGNATURE-----
...
-----END PGP SIGNATURE-----
```

Verifying it (`SZSArchive.verify`):

1. `gpg --status-fd 1 --decrypt` extracts the clearsigned body and signature
   verdict (two-pass: user keyring + SimpleZip-private ring, same merge as
   `.siz`).
2. Decode the JSON manifest. Schema + version + per-path safety checks
   (rejects `..`, absolute paths, Windows drives, UNC, backslashes — even
   though the signer signed them).
3. For each file entry: resolve `<payloadRoot>/<relativePath>`, stream-SHA256
   it, compare to the recorded hash. Classify as `.match` / `.mismatch` /
   `.missing` / `.unreadable`.

The verification sheet shows per-file status with badges; mismatches expand
to reveal expected vs. actual SHA256. The **Browse as virtual folder** button
opens the payload root in folder mode but **only shows `.match` entries +
their ancestor directories** — anything mismatched / missing / unreadable
stays hidden so users can't mistake them for verified content. The address
bar displays `/path/to/manifest.szs` to make the virtual-archive framing
obvious.

Right-click any selection in the file browser → **Create Signed Manifest…**
to generate one. Output defaults to `<payloadRoot>/<folderName>.szs` next to
the signed files.

See [docs/SZS-FORMAT.md](./docs/SZS-FORMAT.md) for the full format spec and
[SECURITY.md](./SECURITY.md#szs-signed-manifest-format) for the threat
model.

## GPG Integration

Settings → GPG gives you the full pane:

- **Five-group keyring partition** by `(source, hasSecretKey, isSecretKeyStub)`:
  local secret keys (`~/.gnupg/`), smartcard / OpenPGP token, SimpleZip-private
  (its own GNUPGHOME), others' public keys (system keyring), others' public
  keys (SimpleZip only).
- **CRUD on keys**: create (RSA 4096 / Ed25519 / NIST P-256 / etc., with
  expiration + passphrase + optional auth subkey), import, export public
  key, export private key, revocation certificate generation, delete with
  destructive confirmation.
- **Maintenance**: change passphrase, add UID, edit expiration, set trust
  level (unknown / never / marginal / full / ultimate), mark as default
  signing key.
- **Smartcard / OpenPGP token support**: detection via `gpg --card-status
  --with-colons`, binding display, "import public key from smartcard" action.
- **Signing strategy**: default key picker (silent) or per-archive ask mode
  with an in-dialog menu picker for multi-key users.
- **SimpleZip-private homedir**: keys you mark "save to SimpleZip-only" live
  in `~/Library/Application Support/SimpleZip/gnupg/` (mode `0700`), fully
  separated from your `~/.gnupg/`. Uninstall the app to wipe them; nothing
  pollutes the system keyring.
- **No passphrase in app process**: all `gpg` invocations except the
  intentional create-key / change-passphrase loopback flow rely on
  `gpg-agent` + `pinentry-mac` for the native macOS passphrase dialog. The
  app never stores or buffers passphrases.

## Safety Model

SimpleZip is intentionally **not sandboxed** — it's a file-management utility
that runs CLI backends, mounts DMGs, opens temporary files, and supports
broad drag-and-drop. That makes the trust boundary explicit: every archive is
untrusted input.

Current guardrails (see [SECURITY.md](./SECURITY.md) for the full threat
model):

- Extraction is staged into a temp directory before merging into the chosen
  destination. Conflicts are surfaced by SimpleZip, not silently overwritten
  by the backend.
- Suspicious entry paths (`../`, absolute, Windows drive, UNC) trigger a
  confirmation gated by **Settings → Archive → Security → Suspicious paths**.
- Symlinks in the staged output trigger a confirmation before they merge or
  open (**Symbolic links** policy).
- Opening `.app` / `.pkg` / scripts / HTML / Office / etc. from inside an
  archive triggers a confirmation (**Active content** policy).
- Passwords ride stdin via a pseudo-terminal — never as visible command-line
  arguments, never in `ps`.
- DMG creation + mount is via macOS `hdiutil`; mounted read-only when
  browsing / extracting.
- Preset password lives in Keychain (`kSecAttrAccessibleAfterFirstUnlock`),
  never in `UserDefaults`, never in process memory beyond a one-launch cache.
  Plaintext reveal requires `LAContext.deviceOwnerAuthentication`.
- `.siz` containers harden the tar layer: rejects non-regular-file entries,
  rejects fourth files, rejects names outside the expected three, rejects
  unsafe `innerArchiveName`.

The three policy gates (`Suspicious paths`, `Symbolic links`, `Active content`)
can each be flipped to **Always block** for shared / public machines.

## Backends

### 7-Zip (bundled)

SimpleZip ships the official 7-Zip 26.01 universal `7zz` binary at
`SimpleZip/Tools/7zz`. Settings supports **Automatic** (bundled → Homebrew →
`PATH`), **Bundled only**, or **System only**. To install system 7-Zip:

```bash
brew install sevenzip
```

### RAR (optional, user-installed)

RAR browsing / extraction works through the bundled 7-Zip. RAR **creation**
needs RARLAB's proprietary `rar`, which can't be redistributed. From a
developer checkout:

```bash
./scripts/install_rar_backend.sh
```

This downloads RARLAB's ARM + x64 packages, fuses a universal binary, and
installs it to `~/Library/Application Support/SimpleZip/Tools/rar`. Public
distribution of an app bundle that includes that binary is not allowed by
RARLAB's license.

### GPG (optional)

Required for `.siz` create / verify and the GPG settings pane. Install with:

```bash
# minimum: gpg + pinentry-mac
brew install gnupg pinentry-mac
# smartcard / OpenPGP token support:
brew install ykman           # YubiKey CLI (optional)
```

The Settings → GPG pane runs a live health check (gpg path, version,
`gpg-agent` status, `pinentry-mac` resolved path) and shows the exact missing
`brew install` command when something's absent.

## File Browser

The main window is also a usable Finder-style browser:

- sidebar with common locations, frequently used folders, tags, pinned paths;
- sortable + reorderable columns: Kind, Application, Last Opened, Date Added,
  Modified, Created, Size;
- copy / cut / paste / move / delete-to-Trash / reveal / drag local files /
  accept external file drops;
- right-click actions: Open, Add to Archive, Extract Here, Test, Hash;
- conflict handling on paste / extract: Replace, Keep Both, Skip, or
  **Replace If Hash Differs** (computes SHA256 on both sides and surfaces a
  diff result).

## Settings

- **General**: startup location (incl. custom path with existence check +
  on-fail dialog), remember last folder, app language, preset password,
  welcome assistant re-run, preferences backup / restore.
- **Archive**: 7-Zip backend mode, RAR backend mode, security policies
  (suspicious paths / symlinks / active content), Finder auto-extract,
  overwrite behavior.
- **Browser**: hidden file visibility, listing columns.
- **File Associations**: per-extension default app management, including
  split-volume groups (`.001`, `.z01`, `.r00`).
- **Columns**: listed columns for the file browser and archive browser.
- **GPG**: main toggle, smartcard toggle, keyring management (five groups),
  defaults sub-section (signing key strategy), advanced (backend paths,
  pinentry-mac status, GNUPGHOME, SimpleZip-private ring path).
- **Health**: first-launch diagnostic dashboard.
- **Backup**: preferences export / import (incl. patch semantics) and
  restore-to-defaults.

Language changes take full effect after restarting SimpleZip.

## Build

```bash
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild \
  -project SimpleZip.xcodeproj \
  -scheme SimpleZip \
  -configuration Debug build
```

Or open `SimpleZip.xcodeproj` and run the `SimpleZip` scheme. CI also builds
the Finder Sync extension target automatically (it's referenced by the main
target).

## Tests

Core regression suite lives in SwiftPM as `SimpleZipCoreTests` — covers
command argument generation, archive listing parsers, split-volume
normalization, exclude rules, selected-entry expansion, ZIP / TAR round
trips, `.siz` wrap / unwrap / metadata determinism, and signing flow stubs:

```bash
/usr/bin/xcrun swift test \
  --scratch-path /private/tmp/SimpleZipSwiftPM \
  -Xswiftc -module-cache-path -Xswiftc /private/tmp/SimpleZipSwiftPM/ModuleCache
```

The Xcode project ships an aggregate target `SimpleZipCoreTests` that runs
the same SwiftPM suite, so the entry point is visible from Xcode too.

## Documentation

- [Chinese Guide](./GUIDE.zh-CN.md)
- [Changelog](./CHANGELOG.md) / [中文更新日志](./CHANGELOG.zh-CN.md)
- [Security Policy](./SECURITY.md) / [中文安全策略](./SECURITY.zh-CN.md)
- [Architecture Notes](./docs/ARCHITECTURE.md)
- [Release Checklist](./docs/release-checklist.md)
- [Contributing](./CONTRIBUTING.md)
- [Bundled Tools Notes](./SimpleZip/Tools/README.md)

## Status

SimpleZip is single-maintainer software, distributed as an unsigned ad-hoc
DMG (Developer ID signing is on the roadmap). The current direction is "a
comfortable native macOS archive client with first-class signed-container
support, that doesn't punish multi-key GPG users". The GPG management surface
is feature-complete as of 0.1.8; `.siz` v3 multi-recipient encryption and
the `.szs` external-signature manifest format shipped in 0.1.9.

## License

MIT. See [LICENSE](./LICENSE).
