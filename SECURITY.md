**English** | [中文](./SECURITY.zh-CN.md)

# Security Policy

This document describes SimpleZip's threat model, the user-facing security controls,
and how to report vulnerabilities.

For implementation-level notes (what each guardrail does today, what test coverage
exists), see the **Safety Model** section in [`README.md`](./README.md#safety-model)
and the architecture notes in [`docs/ARCHITECTURE.md`](./docs/ARCHITECTURE.md).

---

## Reporting a Vulnerability

SimpleZip is a small, single-maintainer macOS utility distributed as a Developer ID
signed and notarized DMG. There is no dedicated security mailbox; please report
security issues using one of:

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
- **macOS Gatekeeper bypass.** SimpleZip is Developer ID signed and notarized;
  Gatekeeper should pass it through cleanly. Unsigned local or PR builds still
  require the user to right-click → Open.
- **Network attacks.** SimpleZip does not make outbound network calls in the
  archive workflows. All network access is user-initiated and limited to:
  the Sparkle update check (EdDSA-signed appcast, see the update section),
  GPG key-server search / receive / publish in Settings → GPG (the request is
  performed by GnuPG's own `dirmngr` against `keys.openpgp.org`, and publishing
  a public key requires an explicit confirmation), the optional RAR backend
  installer script, and the "open project page" menu item. Hardening those
  transports beyond what Sparkle / GnuPG already provide is out of scope.

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

## On-Device AI Assistance — privacy and red lines

The optional AI assistant (Apple's on-device **FoundationModels**, macOS 26+) powers
the inline file/archive suggestions, the report "explain this" helpers, recommended
create/extract settings, the adaptive toolbar, and the Activity Center workbench. It is
**off by default** and designed so that, even when enabled, it can never weaken the
safety guarantees elsewhere in this document.

### Where it runs

- **Entirely on your Mac.** Inference uses Apple's on-device model. Nothing is uploaded;
  there is no network call, no telemetry, no account.
- **In a separate process.** The model runs in a dedicated XPC service / LaunchAgent
  helper, not the main app — so the main binary performs no model inference. Background
  baking only runs when you opt in, on whitelisted folders, while the Mac is idle and
  power conditions allow.
- **The XPC boundary is size-bounded.** Configuration and per-pass input payloads are
  rejected above hard limits (1 MB / 32 MB) before decoding, so a malformed or hostile
  message can't OOM the helper.

### Hard red lines (enforced by design)

- **It only explains, classifies, summarizes, suggests, and drafts.** It **never**
  deletes, moves, overwrites, extracts, signs, approves, bypasses a safety prompt, or
  changes a file, a setting, or a task on its own. Every write-capable action a
  suggestion proposes still routes through the same confirmation / task flow and the
  same path-safety checks as a manual action; read-only checks (hash / test) only show
  their result inline.
- **It never sees secrets.** Passphrases, encryption keys, the contents of encrypted
  archive entries, and decrypted plaintext are **never** sent to the model, indexed, or
  logged. Encrypted-archive entry *names* and ciphertext are excluded from AI input.
- **It is not a safety oracle.** No AI output decides whether an archive is safe to
  extract or whether a signature is valid — those remain rule-based / cryptographic
  (see the `.siz` / `.szs` and path-safety sections). AI may *describe* a result, never
  gate on one.

### What it may read, and your control over it

- Indexing/preread is **whitelist-only and read-only**: only folders you explicitly add,
  only file metadata plus (separately opt-in) non-encrypted text content, used to build a
  local index and short summaries. Non-encrypted paths, names and metadata are not
  treated as secret and may appear in prompts; encrypted content never does.
- Everything is **revocable**: turning the assistant off hides its entry points and stops
  baking, and "clear" wipes everything it built in the background — the file index,
  suggestions, learned ranking, cross-surface feedback and the pending-check queue —
  without touching your real files or your Spotlight results.

---

## Non-destructive file operations

SimpleZip writes to the user's disk in several flows beyond extraction: in-place
archive editing, format conversion, overwrite-on-create, split / combine, and the
copy / move / paste / rename / delete operations. The data-integrity rule across
all of them is **never lose the user's data to a partial failure, and never
silently overwrite**.

- **Atomic overwrite.** Replacing an existing file (creating an archive over an
  existing name, "Replace" in the conflict dialog, finishing an in-place edit or a
  format conversion) writes to a unique temporary path first and atomically swaps
  it in on success. A failed or cancelled operation leaves the original intact —
  the old file is never deleted before the new one exists.
- **In-place archive editing.** Adding / renaming / deleting entries or saving an
  edited file back into a ZIP/7z stages the change on a copy, runs the backend
  (`7zz a` / `d` / `rn`), and atomically replaces the original archive. If the
  backend fails, the original archive is byte-for-byte unchanged. Editing an
  encrypted archive first obtains the password, so new entries are never written
  unencrypted into an otherwise-encrypted container.
- **Per-archive write lock + external-change guard (0.4.3).** All archive rewrites
  (entry add/delete/rename, batch rename, junk cleanup, comment editing) acquire a
  process-wide per-archive write lock, so two write tasks can never race on the
  same file and silently overwrite each other's result; queued tasks report
  "waiting" in their details. Every rewrite also verifies — both before starting
  and again right before the atomic swap — that the archive still matches the
  size/mtime/inode snapshot taken when it was listed. If another app modified the
  file in between, the write stops with an explicit error instead of clobbering
  the external edit.
- **Unsafe in-archive entry paths** (Windows-style `..\` escapes, drive letters)
  are rejected before the backend is invoked, so an attacker-controlled file name
  cannot make an edit write outside the archive's logical tree.
- **Entry names are isolated from switches.** Entry names — untrusted input from a
  possibly-crafted archive — are passed to `7zz a` / `d` / `rn` only **after** a
  `--` end-of-options marker, so an entry literally named `-r`, `-p…`, or any other
  switch-shaped string cannot be interpreted as a 7-Zip option when you edit that
  archive. (This mirrors the extraction-side `--` hardening.)
- **The ZIP archive comment is rewritten natively, not re-packed.** Editing a ZIP's
  whole-archive comment rewrites only the trailing End-of-Central-Directory record
  on a same-directory temp copy and atomically swaps it in; the archive body is
  never touched, and a failure leaves the original intact. Per-entry comments are
  deliberately read-only.
- **Path security report (informational).** On open, listed entries are statically
  scanned for nine suspicious-path families (absolute / `..` / drive / UNC /
  backslash paths, control or bidirectional-override characters, overlong paths,
  setuid bits, outward symlinks, case collisions) and surfaced as a banner +
  report. The report can also be opened from the Actions menu at any time while
  an archive is open; a clean archive shows an explicit all-clear instead of a
  disabled menu item. This is purely advisory — it changes nothing about the
  extraction-time prompts and blocks above.
- **Conflict resolution is explicit.** Extract / paste / drop / create all route
  through one dialog: replace, keep both, skip, *replace only if the SHA-256
  differs*, and — for folders — merge (Finder-style) vs. replace-the-whole-folder
  (tar-style). Nothing is overwritten without a choice or a saved policy.
- **Undo is conservative.** Every undoable file operation re-checks that the source
  is unchanged and the target slot is free before acting, and prefers recoverable
  moves (to Trash) over destructive deletes; steps it can't safely reverse are
  reported, not forced.
- **Permission / owner changes** (`chmod` / `chown`) are undoable (the previous
  mode and owner are snapshotted before the change); `chown` still requires the
  system authorization prompt, exactly like the forward operation.

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

## Encrypted Temporary Scratch Volume (since 0.2.7)

Opening a `.gpg`/`.siz`, browsing an archive, opening a file inside one, or any
extraction produces **plaintext** that has to live somewhere on disk while a
backend tool (7zz / gpg / tar) reads it. Writing that plaintext into the normal
system temp directory (`/var/folders/…`) defeats the point of encryption: a
decrypted copy lingers, readable by anyone with access, until it is cleaned up.

SimpleZip therefore routes **all** decrypt/extract scratch through a per-session
**encrypted disk image** (`SecureScratchVolume`):

### How it works

- On first need (lazily, after launch), SimpleZip generates a **32-byte random
  password** with `SecRandomCopyBytes` that **exists only in process memory** —
  it is never written to disk, Keychain, or anywhere persistent.
- It creates an APFS **AES-256 encrypted sparse image** under the system temp
  dir (`hdiutil create -encryption AES-256 -stdinpass`, password via stdin so it
  never appears in `ps`) and attaches it `-nobrowse` (hidden from Finder).
- Every scratch path (opened-archive items, `.siz` unwrap, `.gpg` decrypt,
  nested-archive extraction, extraction staging) is created **inside the mounted
  volume**.

### Guarantees and limits

- **Normal quit:** the volume is detached and the image file deleted
  (`applicationWillTerminate`) — plaintext is gone.
- **Crash / force-quit:** the image file remains, but it is **AES-256 ciphertext
  keyed by a password that died with the process** — it cannot be re-mounted or
  read. The next launch sweeps any leftover SimpleZip scratch images and
  force-detaches any stale mounts. *Caveat:* between a crash and the next launch
  (or a reboot), a volume that was still attached at crash time stays mounted and
  thus readable at its mount point; only the dormant image file is protected.
- **Fail-closed for encrypted sources:** decrypting a `.gpg`/`.siz` **requires**
  the encrypted volume. If it cannot be mounted, the open **errors** rather than
  falling back to writing plaintext to an unencrypted partition. (Ordinary,
  non-encrypted archive scratch falls back gracefully to the system temp dir if
  the volume is briefly unavailable, so the app never bricks.)
- **Mount verification + self-heal:** before any scratch write, the cached mount
  point is verified to still be a real mounted volume (the mount root's `st_dev`
  differs from its parent's). If the volume was unmounted mid-session (manual
  `hdiutil detach`, system eject), it is detected and a fresh random-key volume
  is **transparently re-mounted** before the decrypt proceeds — so a stale mount
  point (which would otherwise be a plain directory on the real disk) can never
  receive plaintext.
- **Per-archive cleanup:** closing an archive (navigating to a folder, opening a
  different archive) **immediately** purges that archive's scratch, not just at
  quit.

### What this does *not* protect against

- An attacker with **live access to the running session** (your unlocked account
  while SimpleZip is open) can read the mounted volume like any other folder —
  this protects data **at rest after close / crash**, not against a live
  compromise of your logged-in session.
- The random key lives in process memory; if memory is paged to swap it could in
  principle be recovered, but macOS encrypts swap by default.
- It does not replace full-disk encryption (FileVault) for the rest of your data.

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
metadata.json     ← schema = SimpleZip.siz, version = 4 (v2/v3 still accepted)
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
  "version": 4,                                  // v2 = signed-only; v3 += encryption; v4 += deliveryInstructions
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
  },
  "deliveryInstructions": "…optional, signed…"   // human-readable recipient note (#110)
}
```

`deliveryInstructions` (optional, added in 0.3.1) is a human-readable note —
"this is a signed `.siz`, here's how to verify and decrypt it with `tar` + `gpg`",
plus any message the sender typed. It is **deliberately a metadata field, not a
fourth file in the container**: that keeps the "exactly three files" unwrap
hardening intact, and because `metadata.json` is the signature target, the note is
**tamper-proof** (editing it breaks the gpg signature, exactly like every other
metadata field). It carries no secret material (no passphrases, no private keys).
Omitted entirely when absent, so older `.siz` files and the on-disk bytes of
signature-only containers are unchanged.

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

**Exception:** *Generate Key* and *Change Passphrase* run in loopback mode — the
user types the passphrase into a SimpleZip `SecureField` and it is fed to `gpg`
over stdin immediately (generate-key via `--passphrase-fd 0`; change-passphrase
via `--command-fd 0` with `--passwd`, supplying current / new / new-confirm in
turn). **Neither the old nor the new passphrase is ever a command-line
argument**, so nothing appears in `ps` / Activity Monitor and the passphrase is
never stored anywhere. This loopback exception exists because `pinentry-mac`
occasionally fails to present a dialog inside a GUI-app process (hanging on
"generating key…") — a trade-off between reliable UX and keeping the passphrase
out of the SimpleZip process. The keys affected are ones SimpleZip just generated
or is directly modifying, already the most tightly under SimpleZip's control, so
the exception doesn't widen the attack surface.

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
| Old `.siz` v1 (inner-archive-signed) used to bypass metadata sig | `unwrap` rejects `schema != "SimpleZip.siz"` and any `version` not in the accepted set (`{2, 3, 4}`); v1 is refused |
| User opens `.siz` with GPG disabled in Settings                  | unwrap still works; verify is skipped and no signature UI surfaces (so a missing GPG isn't a denial-of-service) |

### v3 multi-recipient encryption (0.1.9)

`.siz` v3 adds optional encryption of the inner `archive.<ext>` payload. The
signed-metadata trust model is unchanged — encryption is layered **inside**
the signed container, not around it.

- **Cipher**: `gpg --encrypt --recipient <fp> ...` (multi-recipient public
  key) **and/or** `gpg --symmetric --passphrase-fd 0` (symmetric). Combined
  invocation yields a packet that accepts decryption via any recipient's
  private key **or** the symmetric password.
- **Inner SHA256 is the *ciphertext* SHA**, not the plaintext. Two
  consequences:
  1. Anyone (including someone without a decryption key) can still verify
     container integrity by re-hashing the encrypted bytes — sig + SHA
     passing is meaningful even to a passive observer.
  2. An attacker who later acquires the plaintext **cannot** re-encrypt with
     a different session key to produce a forgery: gpg's session key is
     randomly chosen per encryption, so any re-encryption yields different
     bytes → SHA changes → signature no longer matches.
- **Recipient list is in the signed metadata**. It's a *claim*, but the
  signature commits to it. An attacker cannot retarget the recipient list
  without invalidating the signature.
- **Symmetric password presence is a flag**, not the password itself. The
  metadata records `hasSymmetricPassphrase: true` so verifiers know to ask
  for a password during decryption; the password never appears in metadata.
- **Decryption passphrase rides stdin** (`--passphrase-fd 0`) — never on
  the command line, never in `ps` / Activity Monitor.
- **Plaintext lifecycle**: after `gpg --decrypt`, plaintext lands in the
  same `SimpleZip-SIZ-Unwrap-*` tempdir as the unwrap. `performExtractArchive`
  uses `defer { try? fileManager.removeItem(at: decryptedSibling) }` to
  remove it as soon as `ArchiveService.extract` returns (success or failure).

What this does **not** protect against:

- **Compromised recipient.** Any recipient's private key recovers the
  plaintext.
- **Weak passphrases.** Symmetric mode is only as strong as the passphrase.
  gpg's CAST5/AES default + S2K iteration helps but doesn't defeat
  dictionary attacks on weak passwords.
- **Pre-encryption side channels.** If the plaintext leaked elsewhere
  before encryption (cache, swap, screen reader), encryption-after-the-fact
  doesn't help.

---

## `.szs` Signed Manifest Format

`.szs` is SimpleZip's other signed-data format — a **GPG-clearsigned JSON
manifest** that points at external files by relative path + SHA256. Use
case: ship a tree of files (release artifacts, mirror snapshot, document
set) and a single `.szs` next to them; recipients verify both the signature
*and* each file's SHA against the values the signer committed to.

### On-disk format

```
-----BEGIN PGP SIGNED MESSAGE-----
Hash: SHA512

{
  "schema": "SimpleZip.szs",
  "version": 2,                        // v1 = original; v2 += instructions (v1 still accepted)
  "createdAt": "2026-05-30T10:23:45Z",
  "createdBy": "SimpleZip 0.1.9",
  "title": "MyRelease v3.1",          // optional
  "files": [
    { "relativePath": "LICENSE.txt",
      "size": 1078, "sha256": "<64 hex>" },
    ...
  ],
  "instructions": "…optional, signed…" // human-readable recipient note (#110)
}
-----BEGIN PGP SIGNATURE-----
...
-----END PGP SIGNATURE-----
```

Deterministic encoding: `JSONEncoder([.prettyPrinted, .sortedKeys])` +
`files[]` sorted lexicographically by `relativePath` — the bytes between
the clearsign markers are byte-identical for the same input, which is what
the signature commits to.

### Two-step verification (`SZSArchive.verify`)

1. **Signature**: `gpg --status-fd 1 --decrypt` against the `.szs` itself
   (clearsign uses `--decrypt` for body extraction; status fd surfaces the
   same `GOODSIG / VALIDSIG / TRUST_*` codes as `.siz`). Two-pass: user
   keyring + SimpleZip-private ring, merged identically to `.siz`.
2. **Per-file SHA256**: decode the JSON body, walk `files[]`, for each
   entry resolve `<payloadRoot>/<relativePath>`, stream-SHA256 it,
   compare. Each entry classifies as `.match` / `.mismatch` / `.missing`
   / `.unreadable`.

### Virtual-folder browse mode

The verification sheet's **Browse as virtual folder** action opens the
payload root in normal folder mode but with a filter that allows **only
`.match` entries + their ancestor directories**. Files that didn't pass
SHA verification (mismatched, missing, unreadable) stay hidden so users
can't mistake an unverified file for a verified one. The address bar shows
`/path/to/manifest.szs` to keep the framing obvious; walking up past the
payload root automatically drops the filter.

### Threat-model summary (`.szs`)

| Attack                                                          | Defense                                                                                                  |
|-----------------------------------------------------------------|----------------------------------------------------------------------------------------------------------|
| Forge `createdBy` / `title` / `files[]` in the manifest         | Clearsigned body covers every byte between the markers → any tampering breaks `gpg --verify`.            |
| Path traversal via `relativePath` (`../escape.txt`)             | `validatedRelativePath` rejects `..`, absolute paths, Windows drives (`C:`), UNC (`\\…`), backslashes — even after sig passes (signer might be compromised). |
| Replace a referenced file with different bytes                  | SHA256 of actual file no longer matches → entry reports `.mismatch`; virtual-folder filter excludes it.   |
| Sneak unreferenced files into the payload root                  | Verification only attests to listed files. The virtual-folder view only shows verified files.            |
| Strip the signature block                                       | `gpg --decrypt` either fails (no signature) or returns mixed plaintext — the parsed `signature` field surfaces the failure.|
| Re-sign manifest with attacker's key                            | The signing fingerprint is exposed; trust is decided by the user's keyring (same UI as `.siz`).         |
| Plaintext leak during verify                                    | `gpg --decrypt` of clearsign just outputs the body; nothing is decrypted-then-cached on disk.            |
| User opens `.szs` with GPG disabled                             | `SZSArchive.peek` requires gpg; sheet shows error rather than misleading "verified" status.              |

### What `.szs` does *not* protect against

- **Confidentiality of the referenced files.** `.szs` is sign-only; the
  files it points at remain as the user laid them out. For confidentiality,
  use `.siz` v3 (encrypted single archive).
- **Compromised signer / weak ownertrust** — same caveats as `.siz`.
- **Files outside the payload root** — the verifier only checks the
  manifest's listed paths. Unreferenced extras are simply not part of the
  verification scope.

---

## Inherited from `.siz`

### What `.siz` does *not* protect against

- **Confidentiality of the inner archive (v2).** v2 `.siz` is a signature
  container, not encryption. If the user wants confidentiality, they use the
  inner archive's native encryption (e.g. AES-256 in `.zip` / `.7z`), or
  upgrade to v3 multi-recipient encryption (above). The signature attests to
  authenticity / integrity, not secrecy.
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

## Sparkle Auto-Update — EdDSA Signature (since 0.1.10)

Sparkle pulls a new version's DMG from a URL listed in
`docs/appcast.xml` on this repository. Since 0.1.10 the client refuses any
update DMG whose `sparkle:edSignature` does not validate against the public
key embedded in `Info.plist` (`SUPublicEDKey`). This closes the gap
documented in the 0.1.8 / 0.1.9 `SparkleUpdater.swift` decision record
("no EdDSA signing yet"), which had left auto-update integrity dependent on
TLS to `raw.githubusercontent.com` plus uncompromised release infrastructure
— neither of which is a cryptographic guarantee.

### What is signed

- **Per release**: the **exact bytes of the published DMG**.
- The signature is computed with `sign_update` from the Sparkle SDK in the
  release workflow (`.github/workflows/release.yml`, step "Sign DMG with
  Sparkle sign_update"). The output `sparkle:edSignature="..."` and `length="..."`
  are inserted **verbatim** into the appcast `<enclosure>` element, so the
  appcast's length and signature describe the same byte sequence the DMG
  upload step pushed to GitHub Releases.
- Sparkle on the user's machine downloads the DMG, computes its Ed25519
  signature against `SUPublicEDKey`, and either installs (signature valid)
  or surfaces the on-screen "could not verify authenticity" alert (any
  mismatch).

### Key locations

| Role                 | Where                                                                                     |
|----------------------|-------------------------------------------------------------------------------------------|
| Public key           | `Info.plist` → `SUPublicEDKey` (44-character base64 Ed25519 public key)                   |
| Private key (CI)     | GitHub Actions secret `SPARKLE_ED_PRIVATE_KEY` (base64 Ed25519 seed)                      |
| Private key (local)  | macOS Keychain, account `simplezip-ci`, plus a gitignored `secrets/` folder for transport |
| Local procedure      | See `secrets/README.md` — `generate_keys`, `pbcopy`, GitHub Secret upload, key rotation   |

The private key is provided to the signing step through a step-scoped,
GitHub-masked environment variable (the recommended way to handle a secret in
Actions — it avoids inlining the secret into the script text and the risk of
shell injection). The step immediately writes it to a `mktemp` file with
`chmod 600`, `sign_update` reads the key from that file, and the file is
deleted before the step finishes. So the key is **never** passed on the command
line and never appears in `ps`, shell history, the appcast, or the build logs —
but it does live in that one step's process environment for the duration of the
step.

### Threat model

**Protected against:**
- MITM on `raw.githubusercontent.com` / `*.githubusercontent.com` (TLS
  break, BGP hijack, malicious root CA installed on the user's machine).
  An attacker can still flip bits but cannot produce a valid signature.
- Tampering with the published GitHub Release after it has been cut.
- A maliciously edited `docs/appcast.xml` on `main` (downgrade attack,
  redirected enclosure URL): the `enclosure` URL bytes still have to satisfy
  the signature.
- A compromised content-delivery edge serving substituted bytes to a subset
  of users.

**Not protected against:**
- A compromised release pipeline (a malicious step inserted into
  `release.yml` could sign any DMG it produced).
- A stolen `SPARKLE_ED_PRIVATE_KEY` — anyone with the key can produce
  signatures that any installed 0.1.10+ build will accept.
- **First-install integrity.** Sparkle EdDSA only protects automatic
  updates *after* the user has a build of SimpleZip installed. The
  *initial* download from GitHub Releases is covered only by TLS + GitHub's
  account security; this is what Gatekeeper + (eventually) Developer ID
  notarization are meant to address.
- Build-environment compromise (a malicious dependency injected into the
  Xcode project at build time would be signed by the legitimate key).

### Rotation / loss recovery

The private key is the only sensitive secret. If it is lost or believed
compromised:

1. Generate a new keypair with `generate_keys --account simplezip-ci`.
2. Replace `SUPublicEDKey` in `Info.plist` with the new public key.
3. Replace the GitHub Actions secret `SPARKLE_ED_PRIVATE_KEY` with the new
   private key.
4. Cut a release as normal.

Users on the prior installed version will accept the next update because
**their installed bundle still embeds the old public key**, and the appcast
is signed by the *old* key. Wait — that's not right when we rotated. The
rotation procedure is unavoidably a one-shot break: after rotation, every
installed user is on a version whose embedded `SUPublicEDKey` no longer
matches the key the new releases are signed with. There is no smooth
transition path that doesn't sacrifice either auto-update for existing users
or the security of the rotation. In practice this means:

- **Only rotate on a confirmed compromise**, not preemptively.
- **Announce a manual re-download** to users when rotating; an automatic
  update will fail with the same "could not verify" alert as a tampered
  DMG.
- 0.1.10 → 0.1.11+ upgrades work fine as long as the key is stable. So
  the "rotation breaks updates" cost is only paid when actually required.

### Upgrade from 0.1.9 to 0.1.10

0.1.9 and earlier did not embed `SUPublicEDKey`, so Sparkle on those
versions ignores `sparkle:edSignature` entirely. The 0.1.10 update is
therefore delivered to those users *without* signature verification (just
TLS, as before). From 0.1.10 onward all subsequent updates are verified.

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
