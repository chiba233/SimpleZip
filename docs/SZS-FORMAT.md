# `.szs` Format — Signed Manifest

**Status**: Draft for 0.1.9 → 0.1.10 implementation. Cryptographic decisions
are deliberately small and conservative; format-level decisions are framed so
the wire format can stay stable while UI / verification report iterates.

[English] · 本文档暂未提供中文翻译，待 v0.1.10 稳定后补译

---

## Why a new format?

`.siz` solves "I want to send **one** archive and have its signature travel
with it" — the contents are a single inner archive, GPG-signed via a wrapping
tar layer. It's an archive container that's been hardened against re-signing
attacks.

`.szs` solves a different problem: **"I want to ship a collection of files
that stay separate on disk, with a single signed manifest that vouches for
each file's integrity."**

Concrete cases this format targets:

1. **Release distributions** — `MyApp.app` + `LICENSE.txt` + `README.md` +
   `Changelog` — keep them as separate files (so users can read README without
   unpacking), but ship one `.szs` next to them so anyone can verify the
   whole drop.
2. **Mirror trees** — periodic snapshot of "what's at this URL", where each
   file's hash gets signed once and stays valid until contents change.
3. **Per-file integrity verification** — given a signed manifest, prove each
   file matches its expected SHA without trusting the channel that delivered
   them (mirror, web folder, etc.).

The "ship as one tar" approach (= `.siz`) is wrong for these — bundling
forces the recipient to unpack before they can use anything, defeats CDN
caching of individual files, and forces re-downloading the whole bundle for
any single-file update.

The "sidecar `.asc` per file" approach (= classic detached signature) is also
wrong — N files = N signatures, each a separate gpg invocation, no single
"sign-the-collection" act.

`.szs` is **one signed file that points at N other files by relative path and
SHA256**. Verifying the drop is two steps: verify the `.szs` signature, then
verify each file's SHA256 against what `.szs` claims.

---

## Format

A `.szs` file is a **GPG clearsigned message** ([RFC 4880 § 7](https://datatracker.ietf.org/doc/html/rfc4880#section-7))
whose body is a deterministic JSON document. That is, the on-disk layout is:

```text
-----BEGIN PGP SIGNED MESSAGE-----
Hash: SHA512

{ ...manifest JSON, deterministic encoding... }
-----BEGIN PGP SIGNATURE-----

iQEzBAEBCAAd... (ASCII-armored signature)
-----END PGP SIGNATURE-----
```

This is what `gpg --clearsign` produces by default. Two reasons to choose
clearsign over a detached signature with a sidecar:

- **One file** — `.szs` is self-contained. No `<thing>.szs.sig` to forget.
- **Human-inspectable** — `cat foo.szs` shows the JSON before the signature
  block. Curl + cat works as an emergency "what does this claim" tool when
  GPG isn't installed.

Encoding constraint: the manifest JSON inside is `JSONEncoder` output with
`[.prettyPrinted, .sortedKeys]`, same encoder as `.siz`'s `metadata.json`.
Determinism matters — the signature is over the literal bytes between the
clearsign markers; round-tripping through a non-deterministic encoder would
break verification.

### Encryption (deliberately out of scope for v1)

`.szs` v1 is sign-only. Encryption use cases that touch this format are
better served by `.siz` v3 (single archive + multi-recipient encryption).
Mixing a per-file manifest with payload encryption introduces edge cases
(per-file decrypt key, mixed encrypted/clear files) that don't have a clear
right answer; deferring keeps the v1 spec small and reviewable.

---

## Manifest schema

Top-level object, schema `SimpleZip.szs`, version 1:

```jsonc
{
  "schema": "SimpleZip.szs",
  "version": 1,
  "createdAt": "2026-05-30T03:04:05Z",        // ISO-8601 UTC
  "createdBy": "SimpleZip 0.1.10",             // creator version
  "title": "MyRelease v3.1",                   // optional display title
  "description": "Public release artifacts",   // optional human-readable note
  "rootDirectoryHint": "MyRelease/",           // optional: suggested layout root
  "files": [
    {
      "relativePath": "MyApp.app/Contents/Info.plist",
      "size": 1234,
      "sha256": "0a1b2c...64 hex...",
      "mediaType": "application/xml"           // optional
    },
    {
      "relativePath": "LICENSE.txt",
      "size": 1078,
      "sha256": "abcdef...64 hex..."
    }
  ]
}
```

Field rules (enforced at create + verify time):

- `schema`: must be exactly `"SimpleZip.szs"`. Any other value rejects.
- `version`: integer. Current = 1. Forward-compat: SimpleZip accepts only
  versions it knows. Unknown version = "this `.szs` was made by a newer
  SimpleZip; please upgrade".
- `createdAt`: ISO-8601 UTC. UI displays in user's local timezone.
- `createdBy`: free-form. Display-only.
- `title`, `description`, `rootDirectoryHint`: optional metadata for UI.
  `rootDirectoryHint` is purely a suggestion — the verifier doesn't enforce
  that files are nested under it; it's a UX cue so SimpleZip can display
  "MyRelease/" as a virtual root and show entries beneath.
- `files[].relativePath`: **must** be a relative path (no leading `/`, no
  `..` components, no Windows drive letters, no UNC). Same restrictions as
  `.siz`'s `validatedInnerArchiveName` but generalized to paths with `/`.
  Path separator is forward slash on the wire. Windows-style backslashes are
  rejected.
- `files[].size`: bytes. Used as a quick mismatch heuristic and to size
  progress bars before hashing.
- `files[].sha256`: 64 lowercase hex characters. SHA256 of the file's exact
  bytes.
- `files[].mediaType`: optional MIME type, UI display hint.
- The `files` array itself must be lexicographically sorted by
  `relativePath`. This is the deterministic ordering the signer + verifier
  agree on. (`JSONEncoder.sortedKeys` only sorts dict keys, not array
  elements; the create flow must sort `files` before encoding.)

Forbidden: duplicate `relativePath` entries; empty `files` array (a
manifest that signs nothing has no purpose — error at create time).

### What's deliberately not in v1

- **No directory entries.** `.szs` describes file leaves only. UI can
  synthesize folder nodes from the relative paths if needed.
- **No symlinks / device files.** Only regular files get signed.
- **No file-mode bits.** The signed property is byte content; permissions
  are local-OS state, not part of the cross-system trust claim.
- **No file timestamps.** Same reason — local mtime is irrelevant to "is
  this the bytes the signer endorsed".
- **No per-file individual signature.** One signature, one signer, signs the
  whole manifest. Multi-signer (countersigning) is a v2 concern.

---

## Verification flow

Inputs: a `.szs` file at `manifestURL`, plus a root directory `payloadRoot`
under which the files referenced by `files[].relativePath` live.

```
SZSArchive.verify(manifestURL:, payloadRoot:)
  → SZSVerifyReport
```

Steps:

1. **Read + decrypt if needed.** If the manifest path ends in `.gpg` /
   `.pgp` / `.szs.gpg`, run `gpg --decrypt` to get the clearsigned text.
2. **GPG-verify the clearsign.** Run `gpg --status-fd 1 --verify` on the
   `.szs` content. Parse the same status codes the `.siz` verify path does
   (`GOODSIG` / `VALIDSIG` / `BADSIG` / `NO_PUBKEY` / `EXPKEYSIG` /
   `REVKEYSIG` / `EXPSIG` / `TRUST_*`).
3. **Parse the manifest JSON.** Extract the body between the clearsign
   markers, decode as `Manifest`. Schema / version checks reject unknown.
4. **Per-file hash check.** For each `files[]` entry, resolve
   `payloadRoot/relativePath`, stream-SHA256 the file (1 MiB chunks like
   `.siz`'s `computeInnerArchiveSHA256`), compare against
   `files[].sha256`. Track per-file status.
5. **Aggregate into report.**

```swift
struct SZSVerifyReport {
    let signature: GPGBackend.GPGVerifyResult   // reuse existing type
    let manifest: Manifest                       // decoded
    let entries: [Entry]                         // one per files[]
    enum Entry: Equatable {
        case match(relativePath: String, sizeBytes: Int)
        case mismatch(relativePath: String, expectedSHA: String, actualSHA: String)
        case missing(relativePath: String)
        case unreadable(relativePath: String, reason: String)
    }
    var summary: Summary {
        // count matches / mismatches / missing / unreadable for UI badge
    }
    struct Summary: Equatable {
        let total: Int
        let matched: Int
        let mismatched: Int
        let missing: Int
        let unreadable: Int
        var allOk: Bool { mismatched == 0 && missing == 0 && unreadable == 0 }
    }
}
```

The `signature` field reuses `.siz`'s `GPGVerifyResult` enum unchanged —
same cases, same fingerprint-strong-comparison semantics if the manifest
claims `signerFingerprint` (it doesn't today; if v2 adds that, the strong
check plugs in for free).

UI surfaces the report as a table:

```
✓ Signature valid (trusted)  signed by: chiba <qwq@qwwq.org>
                              fingerprint: AEBB3BC5...0FF8E3
                              signed at: 2026-05-30T03:04:05Z

Files (12 total, 12 ✓ 0 ✗ 0 missing)
  ✓  LICENSE.txt                          1.05 KB    sha256 abcdef...
  ✓  README.md                            8.21 KB    sha256 0a1b2c...
  ✗  MyApp.app/Contents/Info.plist        — sha256 mismatch (clicking expands)
  ⚠  CHANGELOG.md                         file missing under payload root
  ...
```

Mismatched rows expand to show **expected** vs **actual** SHA256 in
monospace, helping the user diagnose ("oh, I edited this file" vs "the
mirror corrupted it").

---

## Creation flow

Inputs: a root directory + a set of file URLs under it + a signing key
fingerprint + optional `title` / `description` / recipient fingerprints (for
encryption).

```
SZSArchive.create(
    payloadRoot:,
    files: [URL],
    signingKey: String,
    title: String?,
    description: String?,
    recipients: [String]?,    // nil = no encryption (clearsigned only)
    outputURL: URL
) async throws
```

Steps:

1. For each input file, validate it lives under `payloadRoot` (reject
   `..` escapes), compute relative path, compute streaming SHA256, capture
   size.
2. Sort entries by relative path (lexicographic) — deterministic order
   matters for signature stability.
3. Build the `Manifest` struct, fill `signature.signerFingerprint` from the
   signing key.
4. `JSONEncoder([.prettyPrinted, .sortedKeys])` → manifest bytes.
5. `gpg --clearsign --local-user <fp>` → clearsigned bytes.
6. If `recipients` non-nil: `gpg --encrypt --recipient ...` over the
   clearsigned bytes → `.szs.gpg`. Otherwise: write clearsigned bytes
   directly to `outputURL`.
7. Return.

Passphrase handling: same as `.siz` — `gpg-agent` + `pinentry-mac` drives
the dialog. SimpleZip doesn't touch the passphrase.

---

## UI mode

`.szs` introduces a new browser mode beside `.folder` and `.archive`:
`.signedManifest`. Activated when:

- User double-clicks a `.szs` file from Finder, or
- User picks "Open Signed Manifest…" from the File menu, or
- An external file open routes through `openExternalURL` and the extension
  is `szs` (parallel to the existing `.siz` branch).

The mode renders the same Finder-like file table the existing browser uses,
but each row's icon overlays a verification badge (✓ / ✗ / ⚠ / ?). Clicking
a mismatched row opens the per-file diagnostic ("expected sha256 ... actual
sha256 ...").

A header banner shows signer info + overall summary ("12/12 verified" or
"3 files mismatched"). The header is reused from `SIZSignatureStatus` — same
icon / color / title mapping — so visual consistency with `.siz` extract
dialogs stays intact.

Reading / opening individual files works as it does in the folder mode
(double-click opens in default app on a temporary copy if outside payload
root, in place if inside).

Drag-out works (the file's bytes are real on disk; SimpleZip just passes the
URL).

No "extract everything" action — `.szs` already implies the files are at
real paths, so the user just navigates / opens directly.

---

## Use cases worked through

### "Sign a release drop"

```
release/
├── MyApp.app/
├── LICENSE.txt
├── README.md
└── CHANGELOG.md
```

`SimpleZip → File → Create Signed Manifest`, select `release/` as root,
all files auto-discovered, signing key picked from GPG pane's
default. Output: `release/release.szs` (sibling to the contents). Anyone
who downloads the directory can run `gpg --verify release.szs` from the
terminal, or open `release.szs` in SimpleZip for the visual report.

### "Audit a mirror"

User downloaded a tree from a CDN. Author published `tree.szs` at a known
URL with their fingerprint. User downloads `tree.szs` separately, opens it
in SimpleZip pointed at the downloaded tree, gets a per-file report. Any
mismatched / missing entries are flagged immediately.

---

## Threat model summary

| Attack                                                           | Defense                                                                                                            |
|------------------------------------------------------------------|--------------------------------------------------------------------------------------------------------------------|
| Forge `createdBy` / `title` in the manifest                      | The clearsign signature covers all bytes between markers → any byte change invalidates the signature.              |
| Replace a referenced file with different bytes                   | SHA256 of actual file no longer matches `files[].sha256` → that row reports `.mismatch`.                          |
| Add an extra file not in the manifest                            | `.szs` only verifies the listed files. The unlisted file is shown in the UI's "unreferenced files" tray (advisory).|
| Remove a referenced file                                         | The verifier resolves `payloadRoot/relativePath`, gets ENOENT → `.missing`.                                        |
| Swap a file with another file from the same manifest             | SHA256 mismatch on both rows → both report `.mismatch`.                                                            |
| Strip the signature block                                        | `gpg --verify` fails with no signature → `.verificationError`.                                                     |
| Replace the signature with one signed by a different key         | `VALIDSIG` reports the different fingerprint; the UI shows that signer (not the expected one). Optional v2: include `signerFingerprint` in the JSON body so cross-checking with `VALIDSIG` enables a strong-fingerprint badSignature classification (mirrors `.siz` v2 design). |
| Path traversal via `files[].relativePath` (`../escape`)          | `validatedRelativePath` rejects `..`, absolute paths, Windows drive paths, UNC, backslashes — at both create + verify time. |
| Symlink under `payloadRoot` redirects SHA computation off-tree   | SHA256 reads file contents via `FileHandle` — follows symlinks by default, but the path itself must validate first. UI surfaces "this file is a symlink to X" before verifying. |

---

## What `.szs` does **not** protect

- **Confidentiality** of the files themselves. The manifest is signed; the
  payloads remain as the user laid them out. Encryption of `.szs` itself
  hides the manifest content (file list + hashes), but not file contents.
- **Compromised signer.** Standard GPG hygiene applies — revocation,
  expiry, hardware keys are the user's responsibility.
- **The bundled `gpg` binary.** Compromised local gpg is out of scope (same
  as `.siz`).
- **Files outside `payloadRoot`** —  the verifier only checks files at the
  relative paths listed. Extra files in the directory are reported as
  "unreferenced" but aren't part of the verification result.

---

## Differences from `.siz` at a glance

|                          | `.siz`                                | `.szs`                                          |
|--------------------------|---------------------------------------|-------------------------------------------------|
| Files                    | One inner archive                     | N external files                                |
| Container                | tar shell                             | Clearsigned JSON (single file)                  |
| Signature target         | `metadata.json` (in tar)              | The manifest JSON itself (clearsigned)          |
| Signature carrier        | `signature.asc` inside tar            | Inline with the manifest (clearsign block)      |
| Encryption               | `archive.<ext>.gpg` (encrypt payload, v3) | Out of scope for v1 — use `.siz` v3 instead     |
| Verification entry point | `SIZArchive.verify(unwrap:)`           | `SZSArchive.verify(manifest:, payloadRoot:)`    |
| UI mode                  | Archive browser                       | New `signedManifest` browser mode               |
| Strong fingerprint check | v2+, in metadata                      | Planned for v2                                  |

---

## Implementation phases

Tracking against task IDs:

- **#24 part 1** (this document) — design doc, no code.
- **#24 part 2** — `SZSArchive.swift` (Core target): `Manifest`, `create`,
  `verify`, path validation. Pure functions; testable from SwiftPM.
- **#24 part 3** — `GPGBackend.clearsign` + `GPGBackend.verifyClearsign` if
  not already present; reuse `GPGBackend.encrypt` / `decrypt` from `.siz`
  v3 work (#27).
- **#24 part 4** — `Features/SignedManifest/SignedManifestView.swift`:
  new browser mode. `Features/SignedManifest/SZSVerificationReportView.swift`:
  the per-file table. L10n.
- **#24 part 5** — Create flow: a new "Create Signed Manifest…" entry in
  the File menu + sheet (select root + files + signing key + optional
  recipients).
- **#24 part 6** — File association registration for `.szs` UTI; Finder
  Sync extension entry.

Parts 2-3 are SwiftPM-testable and should land first. Parts 4-6 are app-target
and should each be a small focused PR / commit.

---

## Open questions for review

1. **Sidecar `.szs` or inline `.szs` per directory?** This doc assumes
   inline: `release.szs` sits in the directory whose files it covers. An
   alternative is "the `.szs` lives in a sibling location, points at
   `payloadRoot/...` paths the user supplies at verify time". Inline is
   simpler; sibling is more flexible.

2. **Manifest `files[]` ordering — lexicographic or insertion?**
   Lexicographic is deterministic and matches `JSONEncoder.sortedKeys`'s
   spirit. Insertion order would let the signer convey "this is the
   intended display order". Default to lexicographic for v1; revisit if a
   real use case emerges.

3. **Per-file `mediaType`?** Optional in v1. UI uses it as a hint; verifier
   doesn't enforce. Drop entirely if low value.

4. **Should `payloadRoot` default to the `.szs` file's directory?** Yes,
   most natural for the "drop a `.szs` next to the files" pattern. UI lets
   the user override.

5. **`title` / `description` / `rootDirectoryHint` — keep all three or
   merge?** All three are optional. `title` for the verification report
   header; `description` for a longer note. `rootDirectoryHint` is a layout
   cue that's UI-only. Open to dropping one if it's redundant.

6. **Strong fingerprint check (v2)?** Adding `signerFingerprint` /
   `signerUserID` to the JSON body would let SimpleZip do the same
   impersonation defense as `.siz` v2: gpg reports the actual signing fp,
   compared against the manifest's claim. Likely v2 — keep v1 minimal and
   uncontroversial.

Reviewer: leave comments inline on this doc or open an issue tagged
`format/szs`.
