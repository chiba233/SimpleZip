**English** | [中文](./SECURITY.zh-CN.md)

# Security Policy

This document describes SimpleZip's threat model, the user-facing security controls,
and how to report vulnerabilities.

For implementation-level notes (what each guardrail does today, what test coverage
exists), see the **Safety Model** section in [`README.md`](./README.md#safety-model)
and the architecture notes in [`docs/ARCHITECTURE.md`](./docs/ARCHITECTURE.md).

---

## Reporting a Vulnerability

SimpleZip is a small, single-maintainer macOS utility distributed as an unsigned DMG.
There is no dedicated security mailbox; please report security issues using one of:

- **GitHub Security Advisories** (preferred): open a private advisory at
  https://github.com/chiba233/SimpleZip/security/advisories/new
- **Private email**: contact the maintainer through the GitHub profile.

Please **do not** open a public issue for unpatched vulnerabilities — that turns
the ticket into a public exploit recipe before users can update.

What to include:

- exact version (`SimpleZip → About SimpleZip` shows it);
- macOS version;
- whether the issue requires user interaction (and what kind);
- a minimal reproduction archive or input, attached or linked to a private upload.

Expected response: acknowledgement within ~7 days, fix or mitigation timeline
proposed within ~30 days. Critical issues (remote code execution, arbitrary file
write outside the chosen destination, preset-password disclosure) are prioritized.

---

## Threat Model

SimpleZip treats every archive as **untrusted input**. The app is intentionally
not sandboxed because it must run bundled command-line backends and mount disk
images, but that trust must be enforced inside the app's own code.

### In scope

- **Malicious archive entry names** (path traversal, absolute paths, Windows
  drive paths, UNC paths) — flagged by `ArchiveSafety.unsafeEntryNames` and gated
  by the **Suspicious paths** policy.
- **Malicious symlinks** in extracted output — gated by the **Symbolic links**
  policy before merging staged output into the user's chosen destination.
- **Active content** inside archives (`.app`, `.pkg`, scripts, HTML, Office
  documents, etc.) — gated by the **Active content** policy before SimpleZip
  hands the temporary file to macOS or the default app.
- **Backend command injection** via user-supplied raw parameters, file names,
  or passwords — passwords go through stdin (PTY), file names are quoted by the
  Foundation `Process` API, and raw parameters are split with a quote-aware
  tokenizer rather than expanded by the shell.
- **Preset password disclosure** at rest, in memory, and on screen
  (see below for details).
- **`.siz` signed-container tampering** (forged signer metadata, swapped inner
  archive, stripped signature, container bombs) — defenses described in the
  [`.siz` Signed Container Format](#siz-signed-container-format) section below.

### Out of scope (by design)

- **Adversary with arbitrary code execution as the user.** SimpleZip cannot
  defend against a malicious binary already running as you. Preset passwords are
  protected only against on-disk inspection / casual shoulder surfing, not
  against in-process memory inspection.
- **Compromised bundled backends.** If the bundled `7zz` binary in `Tools/` is
  swapped for a malicious one between download and run, SimpleZip will execute
  it. The DMG is built by GitHub Actions from `main` and the published artifact
  is checksum-recorded; users who modify their installed `Tools/7zz` accept the
  risk.
- **macOS Gatekeeper bypass.** SimpleZip is unsigned ad-hoc; the user explicitly
  bypasses Gatekeeper on first launch. This is documented in `README.md`. A real
  Developer ID build is on the Phase 11 roadmap.
- **Network attacks.** SimpleZip does not make outbound network calls in the
  archive workflows. The only network access is the user-initiated RAR
  installer script and the "open project page" menu item.

---

## User-Facing Security Controls

These appear in `Settings → Archive → Security` and `Settings → General`:

| Setting                      | What it controls                                                                                                              | Default |
|------------------------------|-------------------------------------------------------------------------------------------------------------------------------|---------|
| **Suspicious paths**         | Decision when an archive contains `../`, absolute paths, or Windows-style paths.                                              | `Ask`   |
| **Symbolic links**           | Decision when extracted output contains a symlink.                                                                            | `Ask`   |
| **Active content**           | Decision when opening `.app`/script/Office entries from inside an archive.                                                    | `Ask`   |
| **Auto-extract from Finder** | Whether opening an archive from Finder/Services bypasses the browser and extracts directly. Safety prompts above still apply. | Off     |
| **Preset password**          | Auto-fill / auto-try a saved password (see Preset Password Storage below).                                                    | Off     |

Each `Ask` policy can be flipped to `Always allow` or `Always block`. The block
choice is preferred for shared / public machines.

---

## Preset Password Storage

Preset password is opt-in (`Settings → General → Use a preset password`). When
configured:

### At rest

- The password is written to the **macOS Keychain** as a generic password item,
  service `yumeka.SimpleZip.PresetPassword`, account `default`.
- Accessibility is `kSecAttrAccessibleAfterFirstUnlock` — readable only by the
  same code-signed app, only after the user has unlocked their Mac since the
  last reboot.
- It is **never** written to `UserDefaults`. A one-shot migration cleans the
  legacy plist key (`presetPassword`) if it exists from older dev builds.
- Turning the master toggle **off** immediately deletes the Keychain item
  (`SecItemDelete`).

### In memory

- A process-local cache stores the value after the first Keychain read, so the
  user is not asked to authorize Keychain access more than once per app launch.
- The cache is cleared by `clear()` (toggle-off) and updated by `save(_:)`.
- The cache is not persisted; relaunching SimpleZip restarts from an empty cache.

### On screen

- The settings password field is a `SecureField` by default (•••• mask).
- Revealing the plain text requires **local authentication** — Touch ID, or the
  Mac login password as fallback — via `LAContext.evaluatePolicy(.deviceOwnerAuthentication)`.
- A failed authentication does **not** reveal the password and surfaces a
  visible failure message.
- Leaving the settings window resets the field to masked.
- The buffered text and the "Save" button mean closing the window without
  pressing Save discards edits.

### In archives created with the preset

- The password is passed to backends through stdin via a pseudo-terminal,
  not as a command-line argument, so it does not appear in `ps`/Activity Monitor.

If your threat model includes other users on the same Mac, **do not enable**
preset password.

---

## `.siz` Signed Container Format

`.siz` is SimpleZip's single-file signed container. The goal is "a regular
archive that carries its GPG signature with it through email / chat / cloud
storage, where a sibling `.asc` would routinely get separated". This section
documents the cryptographic design and the reasoning behind the choices.

### Container layout

A `.siz` is an **uncompressed** `tar` archive containing exactly three files at
the top level (no subdirectories):

```
archive.<ext>      ← the inner archive, byte-for-byte unmodified
metadata.json     ← schema = SimpleZip.siz, version = 2
signature.asc     ← GPG detached signature (ASCII armor)
```

`tar` is intentionally **uncompressed**: `archive.<ext>` is already a compressed
archive (zip / 7z / rar / tar.gz / …), so re-compressing buys no space and only
costs CPU. The user's original compression options (including AES-256 password
encryption inside `.zip` / `.7z`) are preserved untouched — `.siz` is an outer
shell, not a replacement archive format.

### What is signed, and why

**The signature target is `metadata.json`, not `archive.<ext>`.** This is the
single most important design decision.

If the signature signed only the inner archive (an obvious-looking choice), an
attacker who didn't have the signer's private key could still rewrite *any*
field of `metadata.json` — the signer name, the signing time, the original
filename, the inner format string — and SimpleZip would happily display the
forged values while reporting "signature valid", because the cryptographic
target (the inner archive) hadn't been touched. The signature would mean
"signer at some point signed this archive blob" rather than "signer attests to
this `.siz` as it exists right now". That's a useful primitive for "did this
byte stream come from X" but a poor primitive for "is this signed `.siz`
container what its creator intended".

By signing `metadata.json` instead, any byte change in metadata invalidates
the signature, so:

- changing the signer name → signature fails;
- changing the signing time → signature fails;
- renaming the inner archive (e.g. swapping which `archive.<ext>` is unwrapped) → signature fails because `innerArchiveName` changes;
- changing the recorded inner format → signature fails.

### Inner-archive integrity via SHA256

Signing metadata alone would leave a different attack open: swap `archive.<ext>`
in the tar container for a completely different blob while leaving
`metadata.json` and `signature.asc` untouched. The metadata signature still
verifies; UI still shows the recorded signer; but the user opens an attacker's
payload.

To close this, `metadata.json` includes `innerArchiveSHA256` — the SHA256 hex
of `archive.<ext>` as it existed when the container was created. On verify,
SimpleZip recomputes the SHA256 of the unwrapped inner archive and compares it
to the recorded value. A mismatch is reported as `.badSignature`, even though
the gpg signature on `metadata.json` itself is technically valid: the
*combination* — "metadata is genuine but the inner archive isn't what metadata
claims" — is the actual compromise we're alerting on.

SHA256 is computed in 1 MiB streaming chunks via `CryptoKit.SHA256`, so a 50 GB
inner archive doesn't load into memory.

### What metadata records

```jsonc
{
  "schema": "SimpleZip.siz",
  "version": 2,
  "innerArchiveName": "archive.zip",            // e.g. archive.7z
  "innerFormat": "zip",                          // for UI display
  "originalArchiveName": "MyProject.zip",       // user's chosen name pre-wrap
  "innerArchiveSHA256": "…64 hex…",             // streaming SHA256 of archive.<ext>
  "createdAt": "2026-05-30T03:04:05Z",          // ISO-8601 UTC
  "createdBy": "SimpleZip 0.1.8",                // app version that wrapped
  "signature": {
    "signerFingerprint": "…40 hex…",            // *claim* (verified by gpg)
    "signerUserID": "Alice <alice@example.com>", // *claim* (informational)
    "armorFormat": true                          // signature.asc is ASCII armor
  }
}
```

`signature.signerFingerprint` and `signature.signerUserID` in metadata are
**claims**, not proof. The actual trust comes from gpg verifying
`signature.asc` against `metadata.json`. If the metadata signature fails, the
displayed signer fields are meaningless (and the UI shows a red bad-signature
warning before the user can act on them). If the metadata signature passes,
the recorded signer fields are guaranteed to be the same ones the signer wrote
at wrap time.

### Two-step verification flow

`SIZArchive.verify(unwrap:)`:

1. **`gpg --verify signature.asc metadata.json`** — establishes that
   `metadata.json` was signed by *some* key whose public key is in the user's
   keyring, and whether that key is trusted, untrusted, unknown, or the
   signature is corrupt.
2. **SHA256 check** — only if step 1 returned `.validSignature`, recompute
   `SHA256(archive.<ext>)` and compare to `metadata.innerArchiveSHA256`. On
   mismatch, downgrade the result to `.badSignature(signer:)` — the signer is
   real, but the container they signed no longer matches the file in front of
   the user.

Both failures present identical UI: a red bad-signature dialog where Cancel is
the default action. Users can still force "Open Anyway", but the loud,
default-cancel UI is designed to discourage that on a typical install.

### Deterministic metadata encoding

A signature on `metadata.json` is only meaningful if the bytes signed at wrap
time are byte-identical to the bytes verified at unwrap time. SwiftPM's
`JSONEncoder` with `[.prettyPrinted, .sortedKeys]` is deterministic given the
same `Codable` input, so:

- the create path serializes metadata once via `SIZArchive.encodeMetadata(_:)`,
  writes the bytes to disk, signs **that file** with gpg, then calls
  `SIZArchive.wrap(...)` which uses the **same** encoder to write the
  in-container `metadata.json`;
- the verify path reads the on-disk `metadata.json` straight out of the tar
  without round-tripping through `JSONEncoder` at all.

This eliminates encoder-mismatch as a source of false "bad signature" results
and keeps `SIZArchive` independent of `GPGBackend` (signing remains a caller
concern).

### Passphrase handling

SimpleZip **never** touches the user's private-key passphrase. All `gpg --sign`
and `gpg --verify` invocations rely on `gpg-agent` + `pinentry-mac` to present
the native macOS passphrase dialog. This avoids storing the passphrase anywhere
in the SimpleZip process, including buffers, view state, or Keychain. Users
must install `pinentry-mac` (Homebrew's `gnupg` formula does this automatically);
SimpleZip surfaces a warning in Settings → GPG if it's missing.

### Container hardening before unwrap

Before extracting anything to disk, `SIZArchive.unwrap(at:to:)` lists the tar
entries (`tar -tf` + `tar -tvf` for type info) and rejects:

- entry names that fail `ArchiveSafety.unsafeEntryNames` (path traversal,
  absolute paths, Windows-style paths);
- non-regular-file entries (symlinks, hardlinks, devices, FIFOs);
- duplicate normalized names;
- any entry outside the expected set
  (`archive.<ext>`, `metadata.json`, `signature.asc`);
- a `metadata.innerArchiveName` that doesn't validate as `archive.<ext>` with
  no path separators and no overlap with the metadata/signature filenames.

Only after these checks does SimpleZip call `tar -xf` for the three expected
entries individually (not the whole archive), bounding the unwrap to the named
files.

### Threat-model summary

| Attack                                                           | Defense                                                                                                       |
|------------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------|
| Forge signer name / time / `originalArchiveName` in metadata     | gpg verify of `metadata.json` fails → red bad-signature dialog                                                |
| Swap `archive.<ext>` for a different blob                        | `metadata.innerArchiveSHA256` recomputed and compared → `.badSignature`                                       |
| Strip `signature.asc` from the container                         | `unwrap` requires `signature.asc` to exist; missing → `SIZError.missingContainerComponents`                   |
| Sneak a fourth file (e.g. `notes.html`) into the container       | `unwrap` rejects any entry outside the expected three names                                                   |
| Path traversal via `metadata.innerArchiveName` (`../escape.zip`) | `validatedInnerArchiveName` rejects names with separators / unsafe components before extraction               |
| Path traversal via tar entry names                               | `ArchiveSafety.unsafeEntryNames` check before `tar -xf`                                                       |
| Symlink in the container pointing into user's home               | tar entry type check rejects non-regular-file entries; only `-` (regular file) is accepted                    |
| Old `.siz` v1 (inner-archive-signed) used to bypass metadata sig | `unwrap` rejects `schema != "SimpleZip.siz"` and the encoder's `version != 2` will mismatch                   |
| User opens `.siz` with GPG disabled in Settings                  | unwrap still works; verify is skipped and no signature UI surfaces (so a missing GPG isn't a denial-of-service) |

### What `.siz` does *not* protect against

- **Confidentiality of the inner archive.** `.siz` is a signature container,
  not encryption. If the user wants confidentiality, they use the inner
  archive's native encryption (e.g. AES-256 in `.zip` / `.7z`). The signature
  attests to authenticity / integrity, not secrecy.
- **Compromised signer.** A signer whose private key is stolen can sign
  arbitrary `.siz` containers that verify cleanly. Standard GPG key-management
  practices (revocation, expiry, hardware keys) are the user's responsibility.
- **Trust delegation.** `.validSignature(trusted: false)` means gpg accepted
  the signature but the local keyring has no trust path to the signer. The
  GUI shows this state in green-but-with-fill-difference and a non-blocking
  warning; it does *not* refuse to open. Users who only want fully-trusted
  signatures should configure GPG trust accordingly.
- **The bundled `tar` binary.** `.siz` unwrap relies on `/usr/bin/tar`, which
  is part of macOS. A compromised system `tar` is outside SimpleZip's threat
  model (already covered by "compromised system binaries" being out of scope).

---

## Bundled Backends

| Backend                                  | Source                  | License                                    |
|------------------------------------------|-------------------------|--------------------------------------------|
| `Tools/7zz` (7-Zip CLI, universal)       | https://www.7-zip.org/  | LGPL-2.1, see `Tools/7zip-License.txt`     |
| `Tools/rar` (optional, user-installable) | https://www.rarlab.com/ | RAR shareware, see `Tools/rar-license.txt` |

The 7-Zip binary is shipped inside the DMG. The RAR binary is **not** bundled
by default for licensing reasons; users install it locally via the in-app
"Install RAR backend" flow, which copies the bytes from `Tools/` into the app
support directory and shows the LICENSE / README for review first.

---

## Release Verification

See [`docs/release-checklist.md`](./docs/release-checklist.md) for the
pre-release checks that gate publishing a build.
