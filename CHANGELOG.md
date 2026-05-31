**English** | [中文](./CHANGELOG.zh-CN.md)

# Changelog

## 0.1.10

- **Sparkle updates now require Ed25519 (EdDSA) signature verification**
  - Embedded `SUPublicEDKey` in `Info.plist` so the client refuses any DMG whose `sparkle:edSignature` doesn't match. This closes a previously-acknowledged gap: until now Sparkle could be tricked into installing a tampered DMG if `raw.githubusercontent.com` was MITM'd or the repo was compromised to serve a forged release.
  - CI: `.github/workflows/release.yml` now runs `sign_update` against the built DMG before publishing, reading the private key from the new `SPARKLE_ED_PRIVATE_KEY` GitHub Secret (the key is written to a `mktemp` file, never passed on the command line or env that's visible in `ps`). The resulting `sparkle:edSignature="..." length="..."` is injected straight into the appcast `<enclosure>` instead of computing length separately, so the values can never desync.
  - Keypair generation: handled locally with Sparkle's `generate_keys --account simplezip-ci`. Private key stays in macOS Keychain + a local-only `secrets/` folder (gitignored — see `secrets/README.md` for the upload flow). Public key is in plain sight in `Info.plist`; that's how Sparkle works (only the private signing key is sensitive).
  - Upgrade impact: users on 0.1.9 → 0.1.10 are **not** signature-checked (their installed bundle has no `SUPublicEDKey` yet). From 0.1.10 onward every release must be signed by the CI key; a missing or mis-set GitHub Secret will fail the release workflow loudly rather than ship an unsigned update.
  - Refreshed `SparkleUpdater.swift` doc comment so the "we don't do EdDSA" decision-record no longer misleads future readers.

## 0.1.9

- **Pre-release review fixed 8 bugs** (one full code review pass, all landed before tagging):
  - **P1** `GPGBackend.verifyClearsign` dropped plaintext in its catch branch — when gpg exits non-zero (BADSIG / NO_PUBKEY), the old version returned `Data()`, so users couldn't even see the manifest contents of a `.szs` with a signature problem. Fix: the catch branch now also runs `extractClearsignPlaintext(from: errorOutput)`, so the verification sheet shows the manifest while still surfacing the signature issue.
  - **P1** `.szs` "Browse as virtual folder" wasn't filtering to `.match` entries — the old code built `allowedFiles` from the raw manifest's full file list, which meant `.mismatch` / `.missing` / `.unreadable` entries (i.e. files that didn't pass SHA verification) showed up in the virtual view too. Users could mistake them for verified content. Fix: `onOpenAsVirtualFolder` callback now passes the `VerifyReport`, and `model.openSZSAsVirtualFolder` builds `allowedFiles` only from `.match` entries.
  - **P1** `SIZSignatureSheet` `onOpen` dismissed the sheet before decryption finished — the old code wrote `pendingSIZVerification = nil` outside the Task, so the sheet disappeared immediately. On decryption failure, users had no way to retry from the sheet (change picker / re-enter passphrase); they had to re-open the `.siz` from Finder. Fix: state cleanup moved into the Task's success branch; the failure branch keeps the sheet and just sets `errorMessage`.
  - **P2** `.siz` v3 recipient picker listed SimpleZip-private ring public keys, but `encrypt` only runs against the user homedir — selecting those keys made gpg fail to find the recipient. Fix: new `encryptionEligibleKeys` filter restricts the picker to `source == .userKeyring`.
  - **P2** `SZSArchive.swift` was missing from the SwiftPM target sources — `swift test` couldn't reach the .szs path-validation / manifest-parse / SHA-check logic. Fix: added to `Package.swift` sources; 109 tests still pass.
  - **P2** `SZSVerificationSheet.verifyNow` race — switching `payloadRoot` triggers a second verify Task; if the first one is slow to return, it could overwrite the second's result, leaving the UI inconsistent with the displayed `payloadRoot`. Fix: added a `verifyGeneration: Int` state; Tasks check their captured generation against the current one before writing back.
  - **P2** `CreateSZSSheet.chooseFiles` didn't clear stale error state — after `rejectedCount > 0` painted the red `statusMessage`, that warning lingered through subsequent successful adds. Fix: clear `statusMessage` + `statusIsError` at the start of `chooseFiles`.
  - **P2** `.gpg` suffix check was case-sensitive — `.siz` packages built on other platforms (or by hand) might use `archive.zip.GPG`, and the old code would silently skip decryption. Fix: `.lowercased().hasSuffix(".gpg")` everywhere.



- **`.szs` new feature: "Browse as virtual folder"**
  - The verification sheet gains a "Browse as virtual folder" button at the bottom — clicking it dismisses the sheet and switches the main window into the payload root in folder mode, but **only files referenced by the manifest, plus directories that contain at least one signed file, are shown**; everything else is hidden. The address bar shows a path like `/Users/yumeka/Desktop/Desktop.szs` (via `archiveDisplayOverride = .szs URL`), giving the impression of browsing inside a virtual archive.
  - **Exit semantics**: when the user navigates "Up" past the payload root, `loadFolder` detects it and automatically calls `exitManifestVirtualMode`, returning to the normal Finder-style listing. No explicit exit button required.
  - **Filter implementation**: `ManifestVirtualMode` holds `allowedFiles` and `allowedDirs` (computed from `manifest.files` — the files themselves plus all ancestor directories up to the payload root); `loadFolder` applies the filter after `fileBrowser.contents`.
  - The single entry point is the model's `openSZSAsVirtualFolder(manifestURL:manifest:payloadRoot:)`; ContentView invokes it from SZSVerificationSheet's `onOpenAsVirtualFolder` callback.

- **`.szs` default output name now matches the payload root's folder name (no longer hard-coded `manifest.szs`)**
  - Example: signing files on Desktop → output is `Desktop.szs`, landing inside Desktop. Semantically clearer ("this is the manifest of this folder"), and signing multiple folders at once no longer collides on names.
  - Touches: `CreateSZSSheet.applyPrefillIfAny` (right-click flow's default) + `chooseOutput` (NSSavePanel default name).

- **Bug fix: double-clicking `.siz` / `.szs` always spawned a new window instead of using the current one (two rounds of fixes)**
  - Symptom: with the main window already open, double-clicking a `.siz` or `.szs` in Finder spawned a second main window instead of presenting the signature sheet in the existing one.
  - First-round fix: removed ContentView's `.onOpenURL`, so SwiftUI lacked a hint to clone windows. **Testing showed it still cloned**.
  - Second-round fix (necessary + sufficient): added `.handlesExternalEvents(matching: [])` to the `WindowGroup` to explicitly tell SwiftUI "I handle no external URL / NSUserActivity events". Without this line, SwiftUI still clones a WindowGroup window for LSHandlerRank-routed `.siz` / `.szs` opens to satisfy the "external event must land on a matching scene" contract.
  - Resulting pipeline: AppDelegate.application(_:open:) → `ExternalFileOpenQueue.enqueue` → notification → the existing ContentView's `.onReceive` drains and handles. Cold start covered by the other drain in `.onAppear`. End-to-end one window.

- **Bug fix: Settings → File Associations was missing the `.szs` row**
  - Symptom: `.szs` was already registered in Info.plist under `UTExportedTypeDeclarations`, and Finder could route double-clicks into SimpleZip, but the Settings → File Associations pane didn't list a `.szs` row, so users had no UI to set SimpleZip as the default app for `.szs`.
  - Fix: added a `.szs` entry to `ArchiveAssociationService.supportedAssociations` (title "SimpleZip Signed Manifest", bound to UTI `com.simplezip.szs-manifest`). The pane picks it up automatically.

- **Bug fix: CreateSZSSheet's right-click flow defaulted the output to the wrong location — selecting files on Desktop generated `/Users/yumeka/Desktop.szs` instead of inside Desktop**
  - Root cause: `applyPrefillIfAny` did `.deletingLastPathComponent()` on the payloadRoot (moving up one level) and then appended `<payloadRoot name>.szs` — Desktop's parent is the home folder, so the output landed under home as `Desktop.szs` instead of inside Desktop. The logic was inverted.
  - Fix: now uses `payloadRoot.appendingPathComponent("manifest.szs")` directly — the `.szs` lands as a **sibling next to the signed files**, matching the design doc's "drop a .szs next to the files" pattern.

- **Bug fix: Cmd+A didn't select all files in the main window's file list**
  - Symptom: in the main window with the file table focused, pressing Cmd+A did nothing. Cmd+A is expected to select every file / folder.
  - Root cause: the SimpleZipApp pasteboard CommandGroup's "Select All" button carried `.disabled(!isTextInputFocused)` — literally "only enable when a text input has focus". But the main table is an NSTableView, not a "text input", so the button was permanently disabled and Cmd+A never fired.
  - Fix: removed the `.disabled` clause so the button stays enabled; the selector is now `NSResponder.selectAll(_:)` instead of `NSText.selectAll(_:)` (semantically tighter — NSText and NSTableView both ultimately inherit from NSResponder, and the selector resolves identically). NSTableView's default `selectAll(_:)` implementation selects every row; NSText / NSTextField use the same selector, so sending it to nil (first responder) does the right thing depending on focus.

- **Critical bug fix: Cmd+C / Cmd+V / Cmd+X stopped working in the main window (affected all versions)**
  - Symptom: in the main window, Cmd+C / Cmd+V / Cmd+X / Cmd+A / Cmd+Z all silently did nothing — no error, no feedback. All shortcuts felt "swallowed".
  - Root cause: the address bar's custom `KeyboardTextField` (in `TopBar.swift`) overrode `performKeyEquivalent` to intercept these shortcuts for in-line editing of the path — but **didn't check whether `currentEditor()` was nil**. As long as the address bar had ever been in the first-responder chain (which it stays after the user clicks it once), `performKeyEquivalent` was invoked; when `currentEditor()` was nil, `.copy(nil)` was a no-op, but the function still `return true` — effectively saying "I handled this event" while doing nothing. SwiftUI Commands / NSTableView never received the events, so every shortcut appeared broken.
  - Fix: the `guard` in `performKeyEquivalent` now binds `let editor = currentEditor()`. When `currentEditor()` is nil (the address bar isn't being edited), the method falls through to `super.performKeyEquivalent`, letting the event reach SwiftUI / the responder chain normally.
  - Impact: while the address bar is being edited, Cmd+C/V/X/A/Z still act on the address text; while it isn't, all shortcuts behave as normal macOS shortcuts again.

- **`.szs` usability: right-click "Create Signed Manifest" + CreateSZSSheet layout fix + `.siz` test-archive feature restored**
  - **Right-click entry**: in the local file table, selecting one or more files → right click → "Create Signed Manifest…" (shown only when GPG is enabled and the backend is available). Clicking it opens `CreateSZSSheet` pre-filled with payload root (inferred as the deepest common ancestor directory of the selection) + the file list. **No need to re-pick the root and files inside the sheet**.
  - **`.szs` create sheet layout fix**: each row's label now has a fixed width (88pt) right-aligned, with content filling the remaining space — fixing the earlier issue where labels stretched as wide as their text and TextFields were squashed. Output URL defaults to `<payloadRoot>.szs` in the right-click flow so it's pre-filled.
  - **`.siz` test-archive feature restored**: `ArchiveBrowserModel.testArchive` now detects a `.siz` selection → routes through the same `pendingSIZOpen` flow, with the signature sheet itself acting as the test result (signature + SHA all valid = container intact and untampered = equivalent to "test passed"). Previously `ArchiveService.test` didn't recognize the `.siz` container and just errored out, so `.siz` users couldn't use the Test feature at all.

- **`.siz` open sheet gains decryption UI (picker + passphrase)**
  - When the container is encrypted (`signature.encryption != nil`), `SIZSignatureSheet` now shows a "Decryption key" picker (when recipients are present) + a "Decryption passphrase" SecureField (when `hasSymmetricPassphrase`).
  - The sheet passes the user-entered values to `ContentView` via the `onOpen(decryptionKey, passphrase)` callback, which forwards them to `SIZArchive.decryptInnerArchive`. The passphrase goes via `--passphrase-fd 0` stdin so it **doesn't appear in `ps`**; when both are empty, pinentry-mac takes over (preserving the prior fallback).
  - Same "one or the other" rule as the extract sheet: when our SecureField has input → loopback mode; when empty → gpg-agent + pinentry-mac takes over. Two passphrase prompts never pop simultaneously.

- **`.siz` v3 encryption: multi-recipient public-key + optional symmetric passphrase + decryption picker actually wired**
  - **Format extension**: `SIZArchive.schemaVersion = 3` (unwrap accepts v2 *and* v3 for backward compatibility). `Metadata` gains an optional `encryption: EncryptionInfo?`:
    - `recipients: [{fingerprint, userID}]` — recipients list for public-key encryption (empty array = symmetric-only);
    - `algorithm: "gpg"` — algorithm identifier;
    - `hasSymmetricPassphrase: Bool?` — **flag** indicating a symmetric password is also set; the password itself is **never** written to metadata (sensitive data does not get signed into the container).
  - **Create flow (featureful)**: checking "Sign with GPG" reveals two new UI groups below the signing row:
    - **"Encrypt to recipients"** — Menu picker, lists all public keys in the keyring (including your own), multiple clicks accumulate selections; selected items render as horizontal chips with an × to remove. 0 = no public-key encryption.
    - **"Encryption passphrase (optional)"** — SecureField. **Combinable** with recipient keys (gpg `--symmetric --encrypt` simultaneously) — either a recipient's private key *or* the correct passphrase can decrypt. Leaving both blank = no encryption (v2 sign-only behavior preserved).
  - **Backend**: `GPGBackend.encrypt` runs `gpg --batch --yes [--symmetric --pinentry-mode loopback --passphrase-fd 0] [--encrypt -r <fp> ...] --trust-model always --output <out> <in>` in a single invocation. Passphrase goes via stdin so it **never appears in `ps`**; recipient fingerprints go on the command line (fingerprints aren't sensitive). `--trust-model always` lets unverified third-party public keys still be picked as recipients — the user has already explicitly selected them through the UI, no need for ownertrust to gate the action.
  - **Metadata SHA256 = SHA of the encrypted blob** (not the plaintext). This lets verifiers without a decryption key still check container integrity (signature + SHA passing = container is genuine and untampered), and defeats the "re-encrypt" attack (gpg's session key is random — each ciphertext differs).
  - **Decryption flow**:
    - **Extract path**: `ExtractArchiveOptionsView`'s "Decryption key" picker (UI shipped in 0.1.8) now actually consumes `request.gpgDecryptionKeyFingerprint` and feeds it to `gpg --local-user` as a hint; a new **"GPG decryption passphrase"** SecureField is shown only when `sizSignature.encryption.hasSymmetricPassphrase == true`, and is **completely independent** from the inner ZIP/7z archive's password field. `ArchiveBrowserModel.performExtractArchive` detects `.gpg` suffix + `sizSignature.encryption` → calls `SIZArchive.decryptInnerArchive` to produce a plaintext sibling file, then runs the regular `ArchiveService.extract`; the plaintext is removed in a `defer` so it doesn't linger in `/tmp`.
    - **Open path** (browser mode): `handleSIZOpen` / the SIZSignatureSheet's `onOpen` calls `decryptInnerArchiveIfNeeded` before `model.openArchive`. If the suffix is `.gpg`, it runs `GPGBackend.decrypt` and lets pinentry-mac handle the passphrase prompt (public-key mode + agent cache is the common path); decryption failures surface as a clear error message.
  - **Backend fallback fix**: `gpgDecryptionKeyFingerprint` was a UI-only placeholder in 0.1.8 — in 0.1.9 it actually reaches `gpg --local-user`. Multi-key users' picker selections are now genuinely respected.

- **`.szs` Signed Manifest format v1, end-to-end implementation** (design + Core + GPG + UI + UTI)
  - **Format**: a `.szs` is a GPG clearsigned JSON manifest. **One signed manifest + N external files staying in place** — complementary to `.siz` (single-file container). Use cases: release drops (app + LICENSE + README + checksums.txt), mirror trees, per-file integrity verification. `cat foo.szs` shows the JSON; `gpg --verify foo.szs` works as a one-shot CLI verification; single-file, no sidecar `.sig`.
  - **Schema**: `{schema: "SimpleZip.szs", version: 1, createdAt, files: [{relativePath, size, sha256, mediaType?}], …}`. The `files` array is lexicographically sorted by `relativePath` (precondition for deterministic signatures). No directory entries, no symlinks, no mode bits, no mtime; `relativePath` goes through `validatedRelativePath` which rejects `..`, Windows drives, UNC, backslashes, and other unsafe components. **Full spec at `docs/SZS-FORMAT.md`**.
  - **Core implementation** (`SimpleZip/Core/SZSArchive.swift`): `Manifest` / `FileEntry` / `EncryptionInfo` types + `create(payloadRoot:files:signingKey:title:description:outputURL:)` + `verify(manifestURL:payloadRoot:)` + `peek(manifestURL:)` + deterministic `encodeManifest`. SHA256 reuses `SIZArchive.computeInnerArchiveSHA256` (1 MiB streaming chunks); large files don't blow up memory.
  - **GPG backend** (`GPGBackend`): new `clearsign(plaintextURL:signingKeyFingerprint:outputURL:)` + `verifyClearsign(signedURL:)` → returns `(GPGVerifyResult, plaintext: Data)`. Reuses `.siz`'s `--status-fd 1` parsing and two-pass merge (user keyring + SimpleZip-private ring).
  - **UI**:
    - `SZSVerificationSheet` (verification report) — signature status at the top (reuses `SIZSignatureStatus`'s icon / color / title mapping) + manifest metadata (title / description / created at / file count) + selectable payload root + per-file table with ✓/✗/⚠ badges per row; mismatched rows expand to show expected vs. actual SHA256;
    - `CreateSZSSheet` (creation dialog) — pick payload root + multi-select files + optional title / description + signing-key picker + output location; file list shows relative paths with × buttons to remove; success auto-closes after 1.5s.
  - **Menu + file association**: a "Create Signed Manifest… (⇧⌘N)" entry is added to the File menu (only shown when `gpgEnabled` and the GPG backend is available); `Info.plist` registers the `com.simplezip.szs-manifest` UTI so Finder double-clicks route into SimpleZip.
  - **`ContentView.handleSZSOpen`**: peek manifest → presents `SZSVerificationSheet`, default payload root = the directory containing the `.szs`, with a button to switch to a different directory and re-verify.
  - **Encryption deliberately deferred** — `.szs` v1 is sign-only. Encryption use cases are served by `.siz` v3 (single-archive, multi-recipient); mixing encryption into a per-file manifest introduces too many edge cases.

- **Fix: long GPG encryption / decryption passphrase descriptions broke dialog layout**
  - Symptom: the create dialog's "Symmetric password" placeholder text was too long ("Symmetric password — combined with recipients = either can decrypt"), the SecureField got crushed horizontally; the extract dialog had the same issue.
  - Fix: shortened placeholders to 2–4 words ("Optional · symmetric password" / "GPG symmetric password"), moved the long explanation into a `.caption2` hint line below the SecureField with `.fixedSize(horizontal: false, vertical: true)` for automatic wrapping.
  - **Documenting the GPG passphrase prompt "one or the other" rule**: the encrypt / decrypt functions inject `--pinentry-mode loopback` only when `passphrase != nil`, so our own SecureField replaces pinentry; when the passphrase is empty, gpg-agent + pinentry-mac takes over. **At most one prompts at a time**.

- **Fix: the `.siz` extract dialog's "Decryption key" picker never showed**
  - Old bug (existed since 0.1.8): `isSizExtract` checked `request.archiveURL.pathExtension == "siz"`, but at extract time `archiveURL` is the unwrapped inner archive (`archive.zip` / `archive.zip.gpg`), whose extension isn't `.siz` at all — so the picker was perpetually false.
  - Fix: the predicate is now `request.sizSignature != nil` (only the `.siz` extract path goes through `unwrapAndVerifySIZ` which attaches `sizSignature` to the request).


- **Bug fix (regression from 0.1.8): Sparkle "Check for Updates" said "you're up to date", 0.1.7 users could never receive the 0.1.8 upgrade prompt**
  - Symptom: from a 0.1.7 install, the menu "Check for Updates" reported "SimpleZip 0.1.7 is the current latest version (you're running 0.1.7 (1))" — completely wrong; the appcast was already on 0.1.8.
  - Root cause: 0.1.8's build script changed `CURRENT_PROJECT_VERSION` to the marketing string `RELEASE_VERSION` ("0.1.8"), and the appcast also wrote `sparkle:version="0.1.8"`. But 0.1.7 users' local `CFBundleVersion` is a small build_number integer. Sparkle's `SUStandardVersionComparator` split them as `[1]` vs `[0,1,8]` and compared component-by-component — first component `1>0` → Sparkle considered local newer than feed → permanently "up to date".
  - Fix: **set both `CFBundleVersion` and `sparkle:version` back to a monotonic integer (`BUILD_NUMBER` / `GITHUB_RUN_NUMBER`)**, marketing strings go only into `sparkle:shortVersionString` (display). Both sides of Sparkle's comparison are now single integers, unambiguous forever.
  - Impact: 0.1.7 users will see the upgrade once 0.1.9 ships. **Current 0.1.8 users have the same trap** (local `CFBundleVersion="0.1.8"` vs next release's `sparkle:version=BUILD_NUMBER` will still come out as "feed newer") — both 0.1.7 and 0.1.8 users can recover via 0.1.9 and resume normal Sparkle flow afterwards.
  - Files changed: `scripts/build_unsigned_dmg.sh` (comment + revert to BUILD_NUMBER), `.github/workflows/release.yml` (appcast template `sparkle:version` reverts to `${BUILD_NUMBER}`, BUILD_NUMBER added to step env).

- **Bug fix (regression from 0.1.8): the Settings window mysteriously popped up when opening a `.siz` file**
  - Symptom: after the user opens "Settings" once and closes it, any subsequent `.siz` open causes the Settings window to spontaneously appear.
  - Root cause: `ContentView.ensureMainWindowVisible()` naively iterated `NSApp.windows` and `orderFront`'d every `!isVisible` window. SwiftUI's Settings scene window persists in `NSApp.windows` after close (just hidden), so it got pulled forward along with the main archive window. Sparkle's update window / the About panel would hit the same trap.
  - Fix: added `isAuxiliaryWindow(_:)` doing a substring match (identifier / title containing "settings" / "preferences" / "sparkle" / "update" / "about" plus their localized titles) and excluded those from `ensureMainWindowVisible`'s iteration. `hideMainWindowIfPossible` left untouched (only called from the Finder auto-extract non-.siz path; not part of the .siz trigger chain).

## 0.1.8

- **Multi-key user friendly: signing-key / decryption-key pickers (choose which private key at create and extract time)**
  - **Settings → GPG: new "Defaults" sub-section**: currently one row, a "Signing key strategy" picker — "Silently use default key" (default, single-key users unchanged) / "Ask each time" (multi-key users).
  - **Create-archive dialog · ask mode**: after checking "Sign with GPG", a new "Signing key [chiba · D8B0...]" menu picker appears, listing all `hasSecretKey` keys (including smartcard stubs) plus a leading "Default / let GPG choose" row (falls back to system). Initial picker value = `AppPreferences.gpgDefaultSigningKeyFingerprint`.
  - **Create dialog · auto-scroll**: after toggling sign, the picker appears at the bottom of the ScrollView and previously required manual scrolling to see — now `ScrollViewReader` + `scrollTo("gpgSignAnchor", anchor: .bottom)` auto-scrolls into view, 0.25s animation.
  - **`.siz` extract dialog: new "Decryption key" picker**: lists all `hasSecretKey` keys + leading "Let GPG decide". **Shown only for `.siz` extracts** — generic zip / 7z / rar / tar don't support GPG asymmetric encryption, so the picker would be noise. In 0.1.8 the picker's choice isn't consumed yet (no GPG-encrypted `.siz` exists), 0.1.9 (`.siz` v3 multi-recipient encryption) wires it in; making it functional UI rather than a stub means **multi-key users have the ability to pick which private key to use from day one**, avoiding gpg's default arbitrary selection.
  - **Backend fallback fixed too**: previously the `ArchiveBrowserModel` create path only looked at `options.gpgSigningKeyFingerprint` and blindly picked the "first hasSecretKey" when empty — Finder Sync and other non-dialog entry points totally ignored the `gpgDefaultSigningKeyFingerprint` preference. New fallback order: explicit options choice → prefs default → backend first hasSecretKey.

- **UI consistency fix: font-size mismatch in the `.siz` extract dialog**
  - Symptom: SIZ signature rows (signer / time / fingerprint) were large, Save-to / Password rows were large, but the "Decryption Method" picker and its menu were noticeably smaller — sat together, looked uneven.
  - Root cause: `ExtractOptionsForm`'s `Form` had `.controlSize(.small)` on it — Picker shrinks to small font; Text doesn't follow, so same-row content has different heights. The bottom button row has its own separate `.controlSize(.small)`, so it doesn't depend on the outer one.
  - Fix: removed `.controlSize(.small)` from `Form`. All controls in the Form revert to default body size, visually aligned with Text. Bottom button row unaffected.

- **GPG verify pipeline overhaul: migrated to `--status-fd 1` machine-readable output + fingerprint strong comparison**
  - **Fixes an old bug**: a file signed with a key you marked "ultimate trust" would still show "public key imported but not trusted" in the verify sheet. Root cause: the old parser sniffed stderr for the string `not certified with a trusted signature` — this WARNING is unstable across gpg versions, locale, and trustdb half-synced states. The new parser reads `[GNUPG:] TRUST_ULTIMATE/FULLY/MARGINAL/UNDEFINED/NEVER` status lines directly, matching gpg's actual truth — **"ultimate trust" is now precisely identified as trusted=true**.
  - **Fixed the two-pass merge bug too**: previously, if the same public key existed in both `~/.gnupg` and the SimpleZip-private homedir but only one had ownertrust ultimate, the merge was "first validSignature wins", letting the untrusted pass swallow the trusted one. Now **trusted=true always wins**, with fingerprint-present as the secondary tiebreaker.
  - **New: fingerprint strong comparison**: `.siz` verification now compares the `signerFingerprint` field in the metadata against the actual primary-key fingerprint reported by gpg's `VALIDSIG` status line — **a mismatch is decisively classified as badSignature**. Defense scenario: an attacker grabs a `.siz`, edits the signer name in the metadata, re-signs with their own key, but forgets to / can't change the fingerprint field — without this check, the fake signature would display as "from the original author" and pass.
  - **New "signature valid but needs attention" trio**: `EXPKEYSIG` (key expired) / `REVKEYSIG` (key revoked) / `EXPSIG` (signature itself expired). In these cases the signature is cryptographically valid but **cannot be fully trusted**: sheet title becomes "✓ Signature valid (but signing key has expired / has been revoked)", color downgrades from green to orange, copy spells out the situation (revocation especially matters — usually means the key is suspected compromised).
  - The parser keeps a `parseLegacyVerifyOutput` text fallback, used only when no `[GNUPG:]` status lines are received (extreme fallback for non-GNU gpg implementations); normal GnuPG never hits it.

- **GPG keyring daily-maintenance pair: "Change Passphrase" + "Add User ID" (GPG key management closes out)**
  - The row's "…" Menu / right-click context menu, on `hasSecretKey` rows, gains two new actions below "Export Private Key":
    - **Change Passphrase**: opens a sheet with three SecureField inputs (current / new / confirm). Backend `GPGBackend.changePassphrase` runs `gpg --batch --pinentry-mode loopback --passphrase <old> --command-fd 0 --edit-key <fp>`, with stdin feeding `passwd\n<new>\n<new>\nsave\n`. The old passphrase rides as a command-line arg (**so it appears in `ps`** briefly — seconds — a reliability/security trade-off); the new passphrase goes via stdin (doesn't appear in ps). Leaving the new passphrase empty removes encryption protection and triggers an NSAlert double-confirm.
    - **Add User ID**: sheet with four fields (Name / Email / Comment / Passphrase). A GPG key can hold multiple UIDs (changed email, separate work / personal addresses, alias, etc.) — existing UIDs are not touched. Backend `GPGBackend.addUserID` runs `gpg --batch --pinentry-mode loopback --passphrase-fd 0 --quick-add-uid <fp> "Name (comment) <email>"`, passphrase via stdin.
  - Failure messaging is specific: change-passphrase failure suggests "was the old passphrase entered correctly?" (the most likely cause); add-UID failure forwards gpg's error.
  - **GPG key management closes out here**: local secret / smart card / SimpleZip-private ring partitioning + CRUD + trust levels + default signing key + public/private key import / export + revocation certs + change passphrase / UID / expiration + smart card binding detection — daily and emergency operations are all covered. Next phase shifts to **SimpleZip-specific features built on GPG** (`.szs` signature manifest / `.siz` v3 multi-recipient encryption).

- **Bug fix: keys created in the SimpleZip-private homedir were still grouped under "My keys (local secret key)"**
  - Symptom: after switching to `--homedir`, the new key actually did land in the SimpleZip-private homedir (data was correct), but GPGPane still rendered it in the "My keys (local secret key)" group — mixed with the user's `~/.gnupg/` keys.
  - Root cause: `keyGroupsView`'s `myLocalKeys` filter only checked `hasSecretKey && !isSecretKeyStub`; **it ignored `source`**. SimpleZip-private homedir keys also have `hasSecretKey`, so they spilled into the local group.
  - Fix: split out a fifth group, "My keys (SimpleZip-private · separate GNUPGHOME)", with `source == .simpleZipKeyring` in the filter. The local-secret-key group also gains `source == .userKeyring` to prevent cross-contamination.
  - Five groups now: local secret keys (~/.gnupg/) / smart card / SimpleZip-private / others' public keys (GPG) / others' public keys (SimpleZip-only), sorted by `(source, hasSecretKey, isStub)`. Empty groups don't render.

- **SimpleZip-private keyring switched to `--homedir` (independent GNUPGHOME) — the real fix + default-signing-key fingerprint garbage bug**
  - **Root cause of "Save to SimpleZip-private still writes to ~/.gnupg/"**: last round's `--primary-keyring` addition still didn't work for the user — gpg's behavior for `--no-default-keyring + --keyring + --primary-keyring` on the `--quick-generate-key` path drifts between versions; some versions still write to `~/.gnupg/pubring.kbx`. Patching wasn't enough.
  - **Real fix**: SimpleZip-private operations now use **`gpg --homedir <SimpleZip-gnupg-dir>`** for a fully independent GNUPGHOME. With `--homedir` gpg switches the entire setup (pubring / secring / trustdb / gpg.conf) to that directory; no ambiguity. New path: `~/Library/Application Support/SimpleZip/gnupg/`, with directory permissions enforced to 0700 (a gpg requirement).
  - **True isolation**: under `--keyring`, the private key still lived in `~/.gnupg/private-keys-v1.d/` — only half isolated. Now the private key also lives in `<SZ-home>/private-keys-v1.d/` — **fully isolated**. Uninstalling SimpleZip and deleting `~/Library/Application Support/SimpleZip/` cleans up everything; zero residue.
  - **Automatic data migration**: on first access to the new homedir, if the legacy `<SZ>/keyring/pubring.kbx` exists and `<SZ>/gnupg/pubring.kbx` doesn't, the file is moved over. Users who previously imported public keys to the SimpleZip-private ring don't lose them.
  - **Verify pipeline switched to two-pass**: the previous `--keyring <SZ>` overlay-search trick doesn't apply under homedir mode (homedirs are mutually exclusive). `GPGBackend.verify` now runs two passes concurrently — default homedir (user `~/.gnupg/`) + SimpleZip homedir — and merges by priority `badSignature > validSignature > unknownSigner > verificationError`. The worst-case finding (signature mismatch) is never masked by the other pass's valid result.
  - All SimpleZip-private operations (list / import / sign / verify / setTrust / editExpiration / revoke / delete / createKey / exportSecret) migrate to the `--homedir <SZ>` path; the redundant `--no-default-keyring` / `--primary-keyring` flags are removed.
  - Old `simpleZipKeyringDirectory()` / `simpleZipPubringPath()` / `simpleZipKeyringArguments()` are retained as deprecated aliases pointing at the new homedir path, so the Advanced section's "SimpleZip private ring path" row doesn't regress.
- **Bug fix: the "default signing key" row showed `指纹: ...\"D\", \"8\", \"B\", ...` garbage**
  - Symptom: when the currently-set default signing key fingerprint isn't found in the keyring (the user deleted the key but the preference still holds the fingerprint), the row displayed dozens of lines of `"\"D\""`, `"\"8\""`, etc. — escaped-quote garbage (see screenshot).
  - Root cause: `L10n.format("…%@", defaultSigningKeyFingerprint.suffix(16) as CVarArg)` — `String.suffix(16)` returns a `Substring`, and bridging a Substring to NSObject for printf-style formatting serializes it as a character sequence resembling a JSON array.
  - Fix: wrap with `String(...)` to convert back to a plain String before passing to format.

- **Three GPG keyring UX bugs fixed + missing features added**
  - **"Save to SimpleZip-private keyring" actually wrote to ~/.gnupg/ bug**: user reported that creating a key with the SimpleZip-private radio selected, the new key still appeared in the "My keys (local secret key)" group. Root cause: `createKey` passed `--no-default-keyring --keyring <SZ>` but not `--primary-keyring <SZ>` — some gpg versions ignore the keyring directive for `--quick-generate-key` without `--primary-keyring`, falling back to the default ring. All three flags are now passed together; SimpleZip-ring keys land where the user expects.
  - **"Where's the delete button?" bug**: delete / edit expiration / generate revocation cert / copy fingerprint / export public key were all hidden behind right-click context menu — users never knew right-click was the entry point. Each row gains a visible **"⋯" Menu button** (borderless `ellipsis.circle` icon); clicking it surfaces all actions including delete. The right-click context menu is retained as a power-user shortcut.
  - **Export Private Key feature**: a new menu item "Export Private Key as .asc…" (only visible on rows with `hasSecretKey`). Backend `GPGBackend.exportSecretKey(fingerprint:source:)` runs `gpg --batch --pinentry-mode loopback --passphrase '' --armor --export-secret-keys <fp>`. The exported private key is **still passphrase-encrypted** (gpg doesn't decrypt secring material on export), but importing it on another machine still requires the original passphrase. UI text warns "don't store next to the passphrase" (split storage: private key on a USB stick, passphrase in a password manager).
  - **Create Key sheet gains an authentication-subkey option**: `--quick-generate-key default` previously created only primary (sign+cert) + encryption subkey, no authentication subkey — users wanting to replace SSH keys with their GPG key were left out. The sheet gains a "Subkey configuration" section showing the default two (sign + encrypt) plus an optional toggle "Authenticate — authentication subkey". When enabled, after the primary key is created, `createKey` runs `gpg --quick-add-key <primary> <algo> auth <expire>` in series, using the same algorithm (ed25519 / RSA) as the primary.
  - Backend `createKey` gains an `addAuthenticationSubkey: Bool` parameter and a serialized auth-subkey call. Primary fingerprint is returned as soon as the primary is done; an auth-subkey failure is tolerated (no error thrown) so the UI doesn't report a failure for a key that was actually mostly successful.

- **"Create Key" passphrase moved to loopback mode — works even when pinentry-mac doesn't pop**
  - Last round added gpg-agent pre-launch + streaming status + a Cancel button, but the user reported that pinentry-mac still wasn't appearing (macOS GUI app process environment differences / `gpg-agent.conf` missing `pinentry-program` / other real-world configuration issues). Even with a Cancel button, "I clicked Create and nothing happens" remained a brick wall.
  - **New approach**: the Create Key flow now uses `gpg --pinentry-mode loopback --passphrase-fd 0`. The SimpleZip sheet has SecureField inputs for passphrase + confirmation; the value is piped to gpg through stdin (not on the command line, so it doesn't show up in `ps` or Activity Monitor). It is released as soon as the child process exits; never written to disk; never enters the Keychain.
  - **Security stance refined**: the previous "SimpleZip absolutely never touches the passphrase" was a clean position but it relied on pinentry-mac being 100% available — which it isn't in real environments. Kleopatra / GPG Suite use the same loopback solution. **Other GPG operations (signing, decrypting, trust changes, edit expiration, revocation certificate) still use pinentry-mac** (gpg-agent caches the passphrase, so they don't prompt every time); only the Create Key flow gets the loopback treatment.
  - **No-passphrase double confirmation**: leaving the passphrase blank is permitted but triggers an explicit `NSAlert` warning: "private key is usable by anyone who can read ~/.gnupg/private-keys-v1.d/, use this only for automation / testing". The message names the legitimate use cases (CI, short-lived test keys) and the failure mode (if the machine is compromised, the key is immediately game over).
  - **Confirmation validation**: passphrase + confirm fields are compared; on mismatch a red error reads "Passphrase entries do not match" and creation is blocked.
  - **Passphrase guidance placeholder**: "≥ 8 chars; a memorable phrase + digits + symbols" — basic guidance, not enforced (we don't lock out a legitimate but short passphrase).
  - **Live status text preserved**: the "Starting gpg-agent → Generating key material → Waiting for system entropy" progression still appears, plus a persistent "Stuck too long? Tap Cancel to terminate" hint.
  - Removed the previous blue "Passphrase via macOS native dialog" card from the sheet (no longer applies). Replaced with the actual passphrase input card.
  - Revocation certificate / edit expiration and other pinentry-mac entry points still rely on pinentry; if those also turn out to hang in real environments, they'll migrate in a follow-up.

- **Bug + UX fix: "Create Key" hung at "Generating key…" and the passphrase note wasn't obvious**
  - **Symptoms**: user reported clicking "Create" leaves the sheet stuck on "Generating key…" forever. They also asked "isn't there a passphrase option?" — they didn't know where the passphrase was being set.
  - **Root cause 1 (UI dead-wait)**: the sheet showed only a static `ProgressView` + "Generating key…" text. pinentry-mac may have appeared but been hidden behind other windows / on another Mission Control space / gpg-agent may not have spawned pinentry — and the user could see nothing of what was happening underneath, **and had no Cancel button to recover**.
  - **Root cause 2 (passphrase note not prominent)**: the sheet's "passphrase is handled by gpg-agent + pinentry-mac" line was a single grey caption at the bottom that nobody noticed; users thought SimpleZip didn't support setting a passphrase at all.
  - **Fix**:
    - **Pre-launch gpg-agent**: `createKey` runs `gpgconf --launch gpg-agent` (idempotent) before key generation to make sure the pinentry pipeline is live. Failure here doesn't block (gpg itself also spawns agent on demand).
    - **Streaming status updates**: `createKey` gains an `outputObserver` callback; the sheet parses `--status-fd 1` output for `[GNUPG:] PINENTRY_LAUNCHED` / `PROGRESS need_entropy` / `KEY_CONSIDERED` and updates the text live: "Starting gpg-agent…" / "Generating key material…" / "Waiting for you to enter the passphrase in pinentry-mac…" / "Waiting for system entropy…".
    - **Cancel button**: `createKey` gains an `operationID` parameter; the sheet registers the ID with `BackendProcessRunner`, so the user can hit "Cancel" at any time to kill the gpg process and recover. On cancel the sheet shows "Key generation cancelled".
    - **Passphrase note promoted to a highlighted card**: the sheet now has a blue-tinted card in the middle plainly stating: "After clicking 'Create', gpg-agent will trigger pinentry-mac to show a separate native macOS password dialog asking you to set the passphrase for the new key. SimpleZip never touches the passphrase (more secure + standard). If the dialog hasn't appeared after a few seconds, check the Dock / other Mission Control spaces / Notification Center". Users now clearly know where to enter the password.
    - **Persistent troubleshoot hint**: a grey caption stays under the live status banner: "Can't see the dialog? Check the Dock notification area / other Mission Control spaces / verify pinentry-mac is ready in Settings → GPG → Advanced. Tap 'Cancel' if it's hung too long." If they get stuck they know how to recover.

- **New feature: GPG key lifecycle trio — "Edit Expiration" / "Generate Revocation Certificate" / "Delete Key"**
  - Three new context-menu actions on every key row (after Copy Fingerprint / Export Public Key):
    - **Edit Expiration**: visible only on keys with `hasSecretKey` (gpg needs private-key access). Opens a sheet with a picker for the new expiration (never / 1y / 2y / 5y); applying runs `gpg --edit-key <fpr> expire <duration> save`. Use this to extend an approaching expiration or revive an already-expired key.
    - **Generate Revocation Certificate**: visible only when `hasSecretKey`. Opens a sheet with a reason radio (none / compromised / superseded / not used) and a description textarea. On generate, NSSavePanel asks where to save the `.asc`. The sheet header explicitly explains the "self-destruct switch" semantics of a revocation certificate: **generate it while the key still works and store it on offline media** (USB stick, paper-printed QR); waiting until the private key is actually compromised is too late.
    - **Delete Key**: visible on every key (rendered with destructive role + a Divider above). Uses SwiftUI's `.alert` with destructive style for double confirmation. The message varies by key type:
      - Public-only (`!hasSecretKey`): single confirmation — "only the public key is removed; you can re-import later if needed".
      - Local secret key (`hasSecretKey && !isSecretKeyStub`): emphasizes "private key cannot be recovered; files previously signed cannot be re-signed; content encrypted to you can never be decrypted. Generate a revocation certificate first if you just want to retire the key".
      - Smart-card stub (`isSecretKeyOnSmartcard`): clarifies "only the local stub is removed; the private key on the card is unaffected; re-insert the card + Import Public Key from Smart Card to restore".
  - When the deleted key happens to be the current default signing key, `gpgDefaultSigningKeyFingerprint` is auto-cleared so the UI doesn't dangle a reference to a deleted key.
  - **Passphrase** is requested via gpg-agent + pinentry-mac throughout; SimpleZip never touches the passphrase ([[feedback-gpg-release-emphasis]]).
  - Backend:
    - `GPGBackend.deleteKey(fingerprint:deleteSecret:source:)` — `--batch --yes --delete-secret-and-public-key` or `--delete-keys`; prefixes `--no-default-keyring --keyring <SZ>` for the SimpleZip ring.
    - `GPGBackend.setKeyExpiration(fingerprint:expiration:source:)` — `gpg --command-fd 0 --edit-key <fpr>` fed `expire\n<duration>\nsave\n`.
    - `GPGBackend.generateRevocationCert(fingerprint:reason:description:source:) -> String` — `gpg --armor --command-fd 0 --gen-revoke <fpr>` fed `y\n<reason>\n<desc>\n\ny\n`, returns the ASCII armor body; the caller writes to file.
    - New enum `GPGRevocationReason` (none / compromised / superseded / notUsed).

- **Bug fix: "Set as default signing key" button disappeared from smart-card key rows after disabling the smart-card toggle**
  - User report: with the smart-card toggle on, the OpenPGP-card key has a "Set as default signing key" button; turn the toggle off and the same key is downgraded to "other people's public keys" and the button vanishes — "doesn't make sense".
  - Root cause: the previous round folded `canBeDefaultSigner` together with the smart-card UI toggle ("if smart-card stub AND toggle off → can't be a default signer"), conflating capability with display.
  - Fix: the smart-card UI toggle only affects **display** (group placement, card buttons, card-binding row). The functional check `canBeDefaultSigner = key.hasSecretKey` is back to looking purely at the keyring's secret-key state, decoupled from the UI toggle.
  - Impact: even with smart-card UI turned off, a smart-card key can still be marked as the default signing key; signing through SimpleZip / CLI works as long as the card is inserted and the PIN is entered.

- **New feature: GPG "Create Key…" with dual-keyring destination**
  - The keyring action button row gains a "Create Key…" button that opens a dedicated sheet.
  - **Destination at the top of the sheet** (per the user's request): a radio choice between
    - "Save to ~/.gnupg/ (default)": standard `gpg --quick-generate-key`, public key in `~/.gnupg/pubring.kbx`, private key in `~/.gnupg/private-keys-v1.d/`. Immediately visible to the CLI.
    - "Save to SimpleZip-private keyring (public key isolated)": adds `--no-default-keyring --keyring <SZ>/pubring.kbx` so the public key only goes into SimpleZip's private ring, not the CLI's pubring.
  - **Honest disclosure of the private-key location**: when the user picks the SimpleZip-private option, the sheet plainly states "⚠ The private key still ends up in ~/.gnupg/private-keys-v1.d/" — gpg's secring is global and cannot be redirected via `--keyring`. Full private-key isolation requires `--homedir`, which is a separate workflow. Users should not be misled into thinking they got complete isolation.
  - Form fields: Name / Email / Algorithm picker (Ed25519 recommended / RSA 4096 / 3072 / 2048) / Expiration picker (Never / 1y / 2y / 5y). Basic validation: non-empty name + email contains `@`.
  - **Passphrase** is handled entirely by gpg-agent + pinentry-mac via the system dialog — SimpleZip never touches the passphrase ([[feedback-gpg-release-emphasis]]). The sheet bottom notes: "If no dialog appears, check that pinentry-mac is installed locally."
  - Backend `GPGBackend.createKey(name:email:algorithm:expiration:into:) async throws -> String` runs `gpg --status-fd 1 --quick-generate-key "Name <email>" <algo> default <expire>`, then parses the new key's fingerprint from the `[GNUPG:] KEY_CREATED B <fingerprint>` status line. As a fallback, it scans the rest of the output for any 40-char hex string.
  - On success the keyring auto-refreshes and a confirmation message reads "Created new key: …<short fp>".

- **Bug fix: smart-card keys disappeared entirely after disabling the smart-card toggle**
  - User report: the public key for an inserted OpenPGP card existed locally, but after disabling smart-card support in Settings → GPG, the key vanished from the keyring list entirely.
  - Root cause: `keyGroupsView` only rendered the smart-card group when `gpgSmartcardEnabled` was true; with the toggle off, the smart-card-stub key was excluded from "My keys (local secret key)" (because `hasSecretKey == true && isSecretKeyStub == true`), not eligible for the smart-card group (which was hidden), and not eligible for the "other people's public keys" group (because `hasSecretKey != false`). All three groups missed it, so the entire row vanished.
  - Fix: when the smart-card toggle is off, smart-card-stub keys are now **downgraded** to the corresponding "other people's public keys" group (routed by `.userKeyring` / `.simpleZipKeyring` source). They render alongside regular public keys; the on-card / stripped badges still appear so the user can see the underlying reality, but the "Set as default signing key" button on the row is automatically suppressed (no point letting the user set a default signing key that has no usable local private material).
  - Impact: even when the user disables the smart-card feature (because they don't want the smart-card-specific group), the public key portion is still visible and usable for verification / encrypting to others — they don't feel like data was lost.

- **GPG keyring visual polish + parser bug fix**
  - **Parser fix**: in modern `gpg --list-secret-keys --with-colons` output, smart-card stub markers are not appended to the type field (the old `sec>` / `ssb>` form) — they're placed in **field 14 (index 13)** as the card serial (e.g. `F1D0+0131337E`). The previous parser only checked the type suffix → modern gpg output missed every smart-card marker → the user's "primary + 2 subkeys all on card" key was misfiled into "My keys (local secret key)" instead of "My keys (smart card)", and subkey rows lacked the "on card" badge. Both locations are now recognized (field 14 non-empty → on card; field 14 = `#` → stripped); compatible across gpg versions.
  - **Capability chips on primary row**: previously only subkey rows showed signing / encrypt / auth / certify capability chips; the primary key's capabilities had to be inferred. Now the primary key's lowercase characters in `field 11` (s / e / a / c) each render as a uniform-width chip, so the user immediately sees "what this primary key can do".
  - **"On card" / "stripped" badges promoted to the primary row**: previously buried in a caption (small grey secondary text below); now an orange "💳 on card" / secondary "🗝/ stripped" chip sits inline next to the fingerprint. Smart-card keys are obvious at a glance.
  - **Uniform chip width**: sign / encrypt / auth / certify / on-card / stripped chips now all use a fixed 11-pt icon slot + an equal-width label, so they line up neatly (previously SF Symbol width differences made them jagged).
  - **Collapsible details**: each row gains a "Details ▶" button, collapsed by default — the main row only shows userID / short fingerprint (16-char long key ID) / capability chips / on-card badge / default button / trust picker, keeping the density readable. Click "Details" to expand the full 40-char fingerprint, the on-card explanation, and the subkey list. Each row expands independently.
  - **Button / picker / "Default" chip heights now consistent**: previously "Set as default" was `.controlSize(.mini)`, the trust picker `.small`, and the "✓ Default" chip a custom padding — all three controls visually different heights, making the row's right edge ragged. The button and chip are now aligned to `.controlSize(.small)` height.
  - **`certify` capability now displayed**: the primary key's `c` (certify) bit was previously not exposed; it's now shown as a "Cert" chip (most primary keys have certify; rendered in secondary grey so it doesn't compete with sign / encrypt / auth).
  - **Chips dropped the SF Symbol icons in favor of text only**: the previous round added an icon to each chip, but `signature` is a flourish-style glyph (not a regular icon) and it collided visually with the next-to-it "Sign" / "签" character, producing a messy overlap (see issue screenshot). Chips are now pure-text single-character labels ("Sign / Encr / Auth / Cert"), distinguished by tint and padding instead. Naturally uniform width.
  - **Second smartcard-detection path: ask the card directly**: the previous round only parsed `--list-secret-keys --with-colons` for stub markers, but the field position drifts across gpg versions (some put it as a type suffix, some in field 14, some in field 15). `listKeys` now additionally runs `gpg --card-status --with-colons`, which is authoritative — the card reports its own subkey fingerprints. `smartcardPrimary` / `smartcardSubkey` sets are unioned across both paths — match either and the key is tagged on-card. When no card is inserted, card-status fails silently so the user isn't bothered.
  - **Impact**: the earlier bug where the user's OpenPGP-card primary key was misfiled into "My keys (local secret key)" and the subkey "on card" badge never appeared (even with the smart card toggle enabled) is now automatically fixed.

- **GPG key management Round 2: subkey display, public-key isolation, default signing key, smart-card binding lookup, row context menu**
  - **Subkey list per key**: each primary key now shows an indented list of subkeys with their short fingerprint, capability chips (Sign / Encr / Auth), an "on card / stripped" marker, and an expiry flag. Previously SimpleZip rendered an OpenPGP card with primary + 3 subkeys as a single row, hiding two-thirds of the information any CLI user could plainly see in `gpg --list-keys`.
  - **Fixed smart-card stub marker**: `#` was being misread as the smart-card marker; in reality gpg uses `>` to mean "private key is on a smart card" and `#` to mean "private key has been stripped (removed locally)". Those are semantically distinct, and now they're tracked as separate fields (`isSecretKeyOnSmartcard` / `isSecretKeyStripped`) with their own icon and caption text in the UI.
  - **Private-keyring isolation**: importing someone else's public key into SimpleZip no longer forces it into the user's `~/.gnupg/`. A new "Import to SimpleZip-private keyring…" button writes to `~/Library/Application Support/SimpleZip/keyring/pubring.kbx` instead. Uninstalling SimpleZip cleans up the entire ring; the user's CLI keyring is untouched. The original single import button is split into "Import to ~/.gnupg…" (shared) and "Import to SimpleZip-private keyring…" (isolated). The "Other people's public keys" group is correspondingly split into two subgroups: "shared via GPG keyring" and "SimpleZip only".
  - **Signature verification searches both keyrings**: `SIZArchive.verify` / `GPGBackend.verify` now append `--keyring <SZ>/pubring.kbx` to the gpg invocation, so signatures against keys the user imported into SimpleZip's private ring still verify successfully alongside keys in `~/.gnupg/`. `--keyring` is additive (the default ring still participates), so the user's existing setup is unaffected.
  - **Smart-card binding lookup**: when smart-card support is enabled, a new row at the top of the keyring section reads "Inserted smart card [Detect]". Clicking Detect runs `gpg --card-status --with-colons`, parses serial / vendor / holder / per-purpose subkey fingerprints, and reverse-looks up the local keyring to tell the user "this card is bound to: <UID> · <short fingerprint>". When the card's subkeys can't be matched to any primary key in the keyring, the row prompts the user to run "Import Public Key from Smart Card…" first — rather than leaving them puzzled about why signing fails.
  - **Default signing key**: new `AppPreferences.gpgDefaultSigningKeyFingerprint` preference. A status row at the top of the keyring section shows the current default (UID + short fingerprint + a "Clear" button). Each local-secret / smart-card-stub row gains a "Set as default" button; the currently-selected key shows a green ✓ "Default" chip. The chosen fingerprint becomes the fallback signing key for `.siz` / future `.szs` / direct `gpg --sign` operations when the user doesn't explicitly pick one in the Create Archive dialog.
  - **Per-row context menu**: right-clicking any key row exposes "Copy public key fingerprint" (writes the full 40-character fingerprint to the pasteboard) and "Export public key as .asc…" (NSSavePanel + `gpg --armor --export <fp>`; the correct source ring is automatically used, so an SimpleZip-only key can't accidentally be exported from the user's default ring or vice versa).
  - **Advanced section addition**: a "SimpleZip private ring" row exposes the exact filesystem path of the isolated keyring, letting power users verify with `gpg --no-default-keyring --keyring <path> --list-keys` from the CLI.
  - **Backend**:
    - `GPGBackend.GPGKey` gains `subkeys: [GPGSubkey]`, `source: GPGKeyringSource (.userKeyring | .simpleZipKeyring)`, `capabilities: String`, `isSecretKeyOnSmartcard`, and `isSecretKeyStripped`. The original `isSecretKeyStub` is retained as a computed property so existing callers continue to compile.
    - New struct `GPGSubkey` (fingerprint / capabilities / isOnSmartcard / isStripped / isExpired) with derived `canSign / canEncrypt / canAuthenticate`.
    - New struct `GPGCardStatus` (serial / vendor / holderName / subkeyFingerprints / linkedPrimaryFingerprint).
    - `parseColonsList` rewritten: recognizes `sec>` / `ssb>` smart-card markers and `sec#` / `ssb#` stripped markers; parses subkey records into the primary's `subkeys` list; reads capability flags. `parseFingerprints` now takes a `SecretKeyMode (fullSecret / smartcard / stripped)` enum to disambiguate the three secret-key states cleanly.
    - New methods: `simpleZipKeyringDirectory()` / `simpleZipPubringPath()` / `simpleZipKeyringArguments()`, `listKeys(from:)`, `listKeys()` (merges + dedupes across both rings), `importKey(from:into:)`, `exportPublicKey(fingerprint:source:)`, `setTrustLevel(...:source:)`, `cardStatus()`.
    - `verify()` adds `--keyring <SZ>` so both keyrings are searched.
  - **Privacy / safety invariants**:
    - Keys imported into the SimpleZip-private ring are **never** written to `~/.gnupg/`. Uninstalling SimpleZip plus deleting `~/Library/Application Support/SimpleZip/` cleans up the entire ring; the user's CLI keyring is completely unchanged.
    - The card-binding lookup only matches subkey fingerprints against the local keyring; it never reads PINs or key material from the card itself; and it doesn't spam errors when no card is inserted.

- **Redone: GPG settings pane with strict keyring partitioning, trust-level picker, opt-in smart card support, and a normal/advanced split**
  - The keyring list is no longer a single flat list — it is split into **three groups**: "My keys (local secret key)" / "My keys (smart card / OpenPGP token)" / "Other people's public keys". Keys land in the appropriate group based on `(hasSecretKey, isSecretKeyStub)`. Empty groups don't render a heading.
  - Each row gains a **trust-level Picker** (5 choices: unset / never / marginal / full / ultimate). Selecting a new value immediately invokes `gpg --command-fd 0 --edit-key <fpr>` with `trust\n<menu-number>\ny\nsave\n` fed via stdin, then refreshes the keyring. `expired` / `revoked` keys show a red read-only chip instead, so the user can't "set" a state that gpg reports about the key itself.
  - Smart card support is now **opt-in**: the Advanced section has a `gpgSmartcardEnabled` toggle (off by default). When off, the "Smart card keys" group heading is hidden and the "Import from smart card" button doesn't appear — users who don't use a smart card see the same simple UI as before. When on, smart-card-related UI shows up and "Import Public Key from Smart Card…" runs `gpg --card-status` to ping the card and `--card-edit fetch` to pull the public key into the keyring.
  - The pane is split into **Normal** and **Advanced** layers: Normal is always visible (master toggle / backend badge / install hint / keyring list / action buttons); Advanced is a collapsed `DisclosureGroup` (smart-card toggle / resolved GnuPG path / pinentry-mac status / gpg-agent liveness / `$GNUPGHOME` envvar). Normal users rarely expand Advanced; debugging / smart-card users get every environment detail in one click.
  - The install-command hint now explicitly states it covers smart card support: under `brew install gnupg pinentry-mac` there is now a line saying "the command above also enables smart card / OpenPGP token support (scdaemon ships with gnupg — no extra install needed)" so users don't discover later, after installing, that their smart card isn't recognized.
  - Smart card key rows show an extra red caption: "Secret key is on the card. Sign / decrypt requires the card to be inserted." plus a `creditcard.fill` badge at the lower right of the key icon. Users no longer mistake "every signing attempt with this key fails" for a SimpleZip bug.
  - Backend / Core changes underpinning the above:
    - `GPGBackend.GPGKey` gains `trust: GPGTrustLevel` and `isSecretKeyStub: Bool`. `parseColonsList` parses the `pub` record's field-2 trust character (`u/f/m/n/e/r/-`) and distinguishes `sec` from `sec#` (stub) markers in the secret-key listing.
    - Two new async methods: `GPGBackend.setTrustLevel(fingerprint:to:) async throws` and `importFromSmartcard() async throws -> String`.
    - New enum `GPGTrustLevel` (unknown / never / marginal / full / ultimate / expired / revoked) — one type shared between Core and UI; `userAssignableCases` exposes the picker options (excluding expired / revoked).
    - `BackendProcessRunner` gains `ProcessInputStrategy.staticInput(String)` — the infrastructure that lets `gpg --edit-key` / `--card-edit`-style interactive menus get a fixed command sequence on stdin and then EOF, reusing the existing pipe / cancellation machinery. PIN management and on-card key generation will use the same path later.
    - `AppPreferences.gpgSmartcardEnabled` new key (defaults to false) and added to the preferences-export whitelist.
  - Consistent with [[feedback-gpg-release-emphasis]]: error messages name the responsible party ("Check that the card is inserted and scdaemon can see it") rather than letting users blame SimpleZip.

- **New feature: GPG section added to the Health diagnostics panel and the "Copy diagnostics" report**
  - Settings → Health (`HealthPane`) now includes one GPG backend row — only when GPG integration is enabled (`gpgEnabled == true`), keeping with AGENTS A4 ("when the master toggle is off, no GPG UI appears outside Settings"). The Health pane and the diagnostics export are the documented exceptions where GPG status is allowed to surface even when the toggle is off, because they live inside Settings rather than on the main browsing surface.
  - Four composite states on the row: GnuPG missing → red ✗ (with "Open GPG Settings" fix button); GnuPG present but pinentry-mac missing → yellow ⚠ (signing works but decryption / unlocking private keys hangs because gpg-agent has no native GUI prompt); GnuPG + pinentry present but gpg-agent not running → yellow ⚠ (gpg will spawn it on demand, usually not fatal); all green ✓ → shows keyring totals (`N public, M with secret key`).
  - The "Copy diagnostics" report now includes a `GPG:` section (only when `gpgEnabled == true`): backend path, version, pinentry-mac availability, gpg-agent liveness, `$GNUPGHOME` envvar, keyring totals.
  - **Privacy invariant**: the diagnostics report carries no fingerprints, no user IDs, no email addresses, no public-key material; it never reads any file inside `~/.gnupg/`. Users pasting the report into an issue tracker will not leak key identity information. SECURITY.md will gain a section documenting this invariant alongside the existing `.siz` privacy notes in a follow-up release.
  - `GPGBackend` gains two lightweight probes: `gnupgHome()` reading `$GNUPGHOME` (a user-customized keyring location is the most common root cause of "SimpleZip doesn't see my keys" reports); `gpgAgentAlive() async` running `gpg-connect-agent /bye` to verify the agent is reachable.
  - Error messages follow the `feedback-gpg-release-emphasis` discipline: they tell the user to check local gpg / pinentry / key configuration first, rather than implying SimpleZip is malfunctioning.
  - `OperationDiagnosticsInputs` gains an optional `gpgSection: GPGDiagnosticsSection?` field (default `nil`, so the existing reporter test fixtures remain unchanged); the new `GPGDiagnosticsSection` struct lives in Core with a matching `public init`.

- **New feature: Welcome Assistant gains a "GPG (PGP signing) — optional" step**
  - Step count goes from 7 to 8; the "settings" progress header now reads 1/8..8/8.
  - GPG gets its own dedicated step rather than being folded into the existing "Backend availability" step, because GPG is "a special, opt-in feature" semantically — turning it off keeps SimpleZip behaving as if GPG weren't there at all. Folding GPG into the backend step would mislead users into thinking GnuPG is required for normal archive work; it isn't.
  - The master toggle `gpgEnabled` defaults to off. When the user opts in, the step displays a `BackendStatusBadge` (green ✓ ready / red ✗ not installed); surfaces `brew install gnupg pinentry-mac` via the existing `SystemInstallCommandView` plus a GPGTools download link when GnuPG is missing; and adds a yellow warning when GnuPG is installed but `pinentry-mac` is missing (signing still works, but decryption / unlocking private keys hangs without the native passphrase dialog since `gpg-agent` has no GUI prompt of its own).
  - All visual primitives reuse existing shared components (`BackendStatusBadge(.prominent)` / `SystemInstallCommandView` / `SettingsActionRow`) — same look-and-feel as the existing backend step, so the wizard doesn't develop its own parallel UI vocabulary.
  - A persistent footnote on the step states: "SimpleZip does NOT manage or cache your GPG private-key passphrase — unlocking is handled entirely by your local gpg-agent + pinentry-mac," so users running into GPG issues know to check gpg / pinentry / key trust configuration first rather than filing a SimpleZip bug.
  - The wizard's toggle binds to the same `AppPreferences.gpgEnabled` UserDefaults key as the Settings → GPG pane, so opting in here also enables it in Settings without a separate action.

- **Internal cleanup: 6 rounds of redundancy auditing landed 14 conceptual cuts (≈ −244 lines net, zero behavior change)**
  - A background audit agent swept the whole repo, then the cleanup ran in 6 batches; each batch was gated on the SwiftPM 109-test suite + Xcode Debug build going green before moving on.
  - Dead code: `GPGVerifyResult.iconName` instance property with zero callers; `AppPreferences.gpgVerifyOnOpen` + `gpgSignByDefault` — two "lying UI" toggles that Settings persisted but no business code ever read (pulled the UI rather than implementing fictional behavior; they can come back as part of the real feature work later).
  - Duplicated helpers: the three `copySystemInstallCommand` copies across GPGPane / ArchivePane / WelcomeAssistantView are now owned by `SystemInstallCommandView` itself (pasteboard write + open Terminal); `runRarInstaller` + `beginInstallReview` — two 70-line verbatim copies in Settings RAR section and the Welcome backend step — collapsed into a new `RarInstallerService` (@MainActor enum, two static methods, no new DTOs, reuses the existing `RarInstallAction` / `RarInstallReview`); `BackendStatusBadge` and `BackendAvailabilityRow` (same shape, different style) unified into one component with a `Style.compact / .prominent` parameter; the `defaultArchiveName` `[FileItem]` / `[URL]` overloads (identical bodies) became one; the `hex(_:)` digest helper duplicated in `HashService` and `ArchiveExtractionCoordinator` collapsed.
  - DTO stacks: `ArchiveOperationFailureAlert` (fullMessage + previewLimit + previewMessage) and `ArchiveBrowserModel.errorMessage` were hiding each other; collapsed to a 13-line `ArchiveOperationFailurePreview.truncate(_:limit:)` pure function in Core, with the existing unit test rewired to call the function directly (same assertions, same coverage).
  - UI deduplication: `SidebarButton` / `PinnedSidebarButton` (pin icon + unpin context menu) / `SidebarTagButton` (color circle) — three 90% identical row types — replaced with one `SidebarRowButton<Content>` chrome wrapper, callers pass leading content; `extractDroppedFileURLs(from:completion:)` unifies the two 25-line NSItemProvider drain blocks (main drop zone + sidebar pinned drop); the four TopBar navigation buttons share a `navButton(_:disabled:help:action:)` private helper instead of seven-line repetition.
  - One-publisher / one-subscriber notifications: `.openSIZContainer` / `.extractSIZContainer` (posted by `ArchiveBrowserModel`, consumed only by ContentView) replaced with `@Published var pendingSIZOpen: URL?` / `pendingSIZExtract: URL?` + ContentView `.onChange` — satisfying AGENTS A3 (no 1:1 notifications) and A5 (`.siz` is a tar shell, no new infra around it).
  - `LocationTextKeyCommand` enum + `handleKeyCommand(_:)` intermediary went away; `control(_:textView:doCommandBy:)` now switches on the selector and calls the parent closures directly.
  - The lessons learned in this round were also written into `AGENTS.md` as twelve A1–A12 anti-patterns (no redrawing existing pages for new features; no DTO stacks; no 1:1 NotificationCenter; gating GPG UI behind `gpgEnabled`; treating `.siz` as a tar shell; not editing project version numbers; using the system temp directory with cleanup; no half-wired references; localization required for every new string; matching scope; treating prior instructions as cumulative; not blowing up the diff). The next agent picking up work in this repo gets these in context automatically.

- **`.siz` tamper-resistance hardening (schema bumped to v2, breaking)**
  - The signing target changed from the inner archive to `metadata.json`: under v1 an attacker could rewrite the signer name / timestamp / `innerArchiveName` in `metadata.json` while the inner-archive signature stayed valid, so the UI would display forged information. Mutating any byte of `metadata.json` now makes gpg verification fail outright.
  - Inner archive content is locked by a new `innerArchiveSHA256` field in metadata (streamed SHA256, not loaded whole into memory). `SIZArchive.verify` performs gpg verification of the metadata signature **and** recomputes the inner archive SHA, downgrading to `.badSignature` on mismatch — so swapping the inner archive can't hide either.
  - The inner archive itself is byte-for-byte preserved — every native compression / encryption / format feature continues to work; the outer SHA + signature just wraps around it.
  - Schema bumped to v2; any pre-existing v1 `.siz` will be rejected with schema mismatch on unwrap (no v1 release ever shipped publicly).
  - Metadata tamper-resistance is *not* surfaced as a separate "metadata signed" row in the GUI; tampering only manifests as the existing red bad-signature warning.

- **Signature display: both the standard extract dialog and the signature sheet now show the key fingerprint and signed-at time**
  - Previously, opening a `.siz` via the "Extract" entry showed signature info as a custom card block that visually clashed with the surrounding form rows (destination / password / decryption method). It's now three standard Form rows — `Signature` / `Signed at` / `Key fingerprint` — aligned with the rest of the dialog.
  - The 40-character `signerFingerprint` is now explicitly shown on both the extract dialog and the signature sheet — the key piece of information for verifying signer identity. Signed-at time is also directly visible on both pages (no longer hidden in a tooltip).

- **`.siz` files stay openable when GPG integration is off, but no GPG UI surfaces anywhere on the main interface**
  - Hard rule: when `AppPreferences.gpgEnabled == false`, no "signature" / "public key" / "fingerprint" wording appears anywhere on the main UI. Turning off GPG integration = exiting the GPG mental model entirely.
  - Exception: `.siz` is a registered file type — double-clicking it from Finder must still work. In that case SimpleZip skips verification and routes straight to the standard open / extract path on the inner archive; no signature sheet, no signature row. `.siz` files don't become un-openable just because GPG was disabled.

- **Bug fix: opening a `.siz` and clicking "Go up" jumped to `/var/folders/.../T/SimpleZip-SIZ-Unwrap-...`**
  - Cause: after opening a `.siz` container, `mode = .archive(innerArchiveURL)` carries the `/tmp` path; the archive-root branch of `goUp` simply called `url.deletingLastPathComponent()` and landed in the unwrap temp directory.
  - Fix: `goUp` now uses `(archiveDisplayOverride ?? url).deletingLastPathComponent()`. Regular archives behave as before; `.siz` containers correctly go up to the original `.siz` file's parent directory (Desktop, Downloads, or wherever the user got it).

- **Internal cleanup: `.siz` verification / signature-display DTO stack collapsed**
  - Deleted `SIZVerificationOutcome` (the existing `GPGVerifyResult.verificationError` covers backend failures; missing backend now reuses the same case with a clear message).
  - Deleted `SIZUserIntent` (open vs extract were already two separate handlers — using an enum to distinguish them was pure overhead).
  - Deleted `SIZSignatureInfo` struct + nested `Status` enum + the 50-line `makeSignatureInfo()` mapper. They've been unified into one `SIZSignatureSummary` whose state derives directly from `GPGVerifyResult`.
  - Deleted `SIZSignatureSheet.SignatureUIState` and its 60-line 6-case mapping; the icon / color / title mapping is now a shared `SIZSignatureStatus` enum used by both the extract dialog rows and the signature sheet — no more two parallel switches.
  - Merged the duplicate unwrap + verify blocks in `handleSIZOpen` / `handleSIZExtract` / `startSIZVerification` into a single `unwrapAndVerifySIZ` helper; both entry points are now under 10 lines each.
  - Net effect: `.siz`-specific symbol references in ContentView dropped from 31 to 13; `SIZSignatureSheet.swift` went from 208 → 100 lines.

- **New feature: GPG integration (Phase A foundation + keyring + .siz signed container)**
  - New Settings → "GPG (PGP Signing)" pane (sidebar position 6, `key.fill` icon): master enable toggle, backend status badge with version, pinentry-mac missing warning, install hints (`brew install gnupg pinentry-mac` with copy + open-in-Terminal buttons; GPGTools download link), keyring list (filled key icon = secret key present), "Import key…" button, and two default-behavior toggles.
  - Master toggle `gpgEnabled` defaults to off — when off, every other GPG entry point (e.g. the Create-Archive "GPG sign" checkbox and the future verification badges) is hidden so users who don't use GPG aren't bothered; the Settings pane itself is always reachable so users can opt in.
  - `Core/Backends/GPGBackend.swift` (~370 lines) handles path discovery (`/opt/homebrew/bin/gpg` / `/usr/local/bin/gpg` / `MacGPG2` / `$PATH`), version, `hasPinentryMac()`, `listKeys()` (state-machine parsing of `--with-colons` cross-referenced with secret keys), `importKey(from:)`, `sign(archiveURL:signingKeyFingerprint:)`, and `verify(archiveURL:signatureURL:)` returning a `GPGVerifyResult` (valid trusted / valid untrusted / unknownSigner / badSignature / verificationError).
  - **The `.siz` single-file signed container** (signature feature): when GPG sign is checked during Create Archive, the output is renamed to `<name>.siz` containing `archive.<ext>` + `metadata.json` (`SimpleZip.siz` schema v2) + `signature.asc` packed via tar (no extra compression — the inner archive is already compressed). One file means the signature never gets separated from the archive in transit, addressing the most common failure mode of the standard `.asc` sibling-file convention. `Core/SIZArchive.swift` exposes `wrap` / `unwrap` / `peekMetadata` / `verify` / `computeInnerArchiveSHA256` / `encodeMetadata`.
  - Opening a `.siz` now unwraps to a scoped temporary directory, runs `SIZArchive.verify` (gpg verifies the metadata signature + the inner archive SHA is recomputed and compared), and shows a SwiftUI signature sheet before browsing the inner archive. The sheet distinguishes valid trusted, valid-but-untrusted, unknown signer, bad signature, and verification error states; bad signatures make Cancel the default action while still allowing an explicit "Open Anyway".
  - The browser keeps the user's mental model intact after opening a `.siz`: the inner archive lives in a temporary folder, but the title and location bar display the original `.siz` path instead of the temporary `archive.<ext>` path.
  - `.siz` container handling is now hardened before extraction: SimpleZip lists and validates tar entries first, rejects unsafe paths, symlinks, duplicate entries, unexpected files, and invalid `metadata.innerArchiveName`, then extracts only `metadata.json`, `signature.asc`, and `archive.<ext>`. Existing `.siz` destinations are no longer silently overwritten.
  - Split-volume archives are intentionally not supported inside `.siz`. If the user enters a split volume size in the Create Archive sheet, the GPG `.siz` signing checkbox is disabled and an inline red message explains that split archives should use an external `.asc` signature file instead. The backend also rejects split-volume and "delete source after compression" combinations as a safety fallback.
  - GPG private-key passphrases are handled entirely by `gpg-agent` + `pinentry-mac`'s native dialog — SimpleZip never touches the passphrase itself (a security-sensitive surface). All it needs is a Homebrew gnupg install that pulls in pinentry-mac (the default).
  - Preferences export whitelist now includes `gpgEnabled` / `gpgSignByDefault` / `gpgVerifyOnOpen`. Private and public keys live in `~/.gnupg/` and are never exported.
  - `.siz` UTI is registered too: `com.simplezip.siz-archive` is declared in `UTExportedTypeDeclarations` (conforms to `public.tar-archive` / `public.archive`), `CFBundleDocumentTypes` has `siz` plus the MIME type `application/x-simplezip-siz`, and `ArchiveAssociationService` lists the new format — so Settings → File Associations lets the user set SimpleZip as the default app for `.siz`.
  - **Still to come in later rounds**: one-click import flow for unknown signers, GUI key creation / export / delete, and smartcard management.

- **Bug fix: Sparkle "Check for Updates" showed self-contradicting messages**
  - Symptom: clicking "Check for Updates" sometimes displayed "0.1.7 available (you have 0.1.6)" and other times "You're on the latest version", contradicting each other.
  - Root cause: Sparkle's update **dialog text** is rendered from `CFBundleShortVersionString` (the marketing version, e.g. `0.1.7`), but its **version comparison** uses `CFBundleVersion` (which CI was setting to `GITHUB_RUN_NUMBER`, e.g. `47`). The appcast had `sparkle:version="0.1.7"`, parsed as `[0,1,7]` vs `[47]` → Sparkle always considered the local build newer → the comparison and the displayed text were measuring different things.
  - Fix: `scripts/build_unsigned_dmg.sh` now sets `CURRENT_PROJECT_VERSION` to `RELEASE_VERSION` during release builds (instead of `BUILD_NUMBER`), so `CFBundleVersion` and `sparkle:version` are both the semver string (e.g. `0.1.7`) on the same comparison path. Users on the next `v0.1.8` release will get a proper "update available" prompt again.

## 0.1.7

- **Internal refactor: `ArchiveBackend` protocol landed (Phase 4 step 6 — Phase 4 complete)**
  - New `Core/Backends/ArchiveBackend.swift` (55 lines) declaring the protocol and adding conformances to all four backends.
  - Protocol scope is intentionally narrow: only the **read path** (`list` / `test`). Those two methods have signatures that line up across every backend, so unifying them collapses `ArchiveService.list` / `.test` into two-line routers (`backendType(for:).list(...)` / `.test(...)`); the switch statements there are gone.
  - The write path (`extract` / `create`) **stays out of the protocol**: backend parameters are too heterogeneous (`NativeZip` needs `zipDecryptionMethod`, `SevenZip` needs `pathMode`, DMG needs neither; plus 7-Zip has three creation variants, NativeZip has three, RAR has one). Forcing them into a kitchen-sink options type would be worse than the current case dispatch.
  - Three small adapter extensions: `NativeZipBackend` / `DiskImageBackend` wrap their existing methods so the protocol's `password` / `operationID` parameters are absorbed (they don't apply); `SevenZipBackend` already matches the signatures directly, so its conformance is an empty extension.
  - After the full 6 steps of Phase 4, `ArchiveService.swift` is down from the original **1524 → 598 lines** (**−926, −60.7%**); the four backends total 1085 lines, each with a clear concern (DMG 208 / NativeZip 310 / RAR 218 / 7-Zip 349 / protocol 55).
  - **Phase 4 complete ✓**

- **New feature: Finder auto-extract now runs in a standalone floating window**
  - Previously, enabling "Auto-extract on Finder open" raised the entire main window to run the extraction, which contradicted the "double-click = silent background extract" expectation users reported.
  - Added a dedicated `ExternalExtractWindowController` + `ExternalExtractSession` that own their own `ArchiveExtractionCoordinator`, run `ArchiveService.extract` independently, and route progress only to this floating window — the main window stays out of the loop entirely.
  - The window is ~360×190, `.utilityWindow` style, `.floating` level, fixed size; it does not steal focus from the main app and only has a close button in the title bar.
  - Progress bar + current file name + cancel button; success auto-closes after 1.2 seconds plus a `NSWorkspace.activateFileViewerSelecting` to reveal the extracted folder. Failures stay on screen so the user can read the error.
  - `ContentView.openExternalURL` detects `finderOpenAutoExtract` + non-DMG and routes to the new controller, then `orderOut`s the main window to handle both cold-launch and hot-launch.
  - DMGs still go through the model's mount-and-browse flow (no "extract" semantics).

- **Bug fix: file association UI doesn't refresh after setting the default**
  - Clicking "Set as Default" in Settings → File Associations didn't show the green checkmark immediately; the user had to switch panes and switch back.
  - Root cause: `LSSetDefaultRoleHandlerForContentType` is synchronously successful, but the same process briefly reads the old cache from `LSCopyDefaultRoleHandlerForContentType` right after.
  - Fix: after the write, refresh immediately and then retry the refresh at 300 ms / 800 ms / 1.5 s so LaunchServices has time to settle and the UI catches up without the user touching anything.

- **Internal refactor: RarBackend extracted + 7-Zip creation moved (Phase 4 step 5)**
  - New `Core/Backends/RarBackend.swift` (218 lines) owns the entire RAR surface: path discovery (local / system candidates); metadata (`backendDescription` / `version`); local install management (`localBackendURL` / `hasLocalBackend` / `deleteLocalBackend`); install resources (`installReadmeURL` / `installLicenseURL` / `installerScriptURL` / `installResourcesURL`); the `create` action; and the `ResolvedRarTool` / `RarToolSource` types.
  - `ArchiveService`'s public RAR facade (`canCreateRAR` / `rarBackendDescription` / `rarVersion` / the install-resource URLs / `hasLocalRarBackend` / `deleteLocalRarBackend`) all became one-line forwarders, keeping the existing Settings RAR pane / welcome assistant backend step / health check call sites working untouched.
  - The same step moved the five 7-Zip creation paths (`.zip` 7zz-preferred / `.sevenZip` / `.gzip` / `.bzip2` / `.xz`) into `SevenZipBackend` via three new methods (`createZip` / `createSevenZip` / `createSingleFileCompressed`). Each `case` branch in `ArchiveService.createArchive` is now a one-line forward.
  - The four ArchiveService private helpers (`sevenZipTool` / `resolvedSevenZipTool` / `run` / `runAndCapture`) are now unreferenced and removed.
  - After steps 1 + 2 + 3a + 3b + 4 + 5, `ArchiveService.swift` is down from 1524 to **601 lines** (cumulative −923, **−60.6%**). Step 6 will reduce the remainder to a pure router plus safety policy + shared path helpers via the `ArchiveBackend` protocol.

## 0.1.6

- **New feature: Welcome Assistant wizard (first-launch + menu)**
  - 11-step guided setup: backup restore → version check → intro → language → startup location (with a "Choose Custom Folder…" NSOpenPanel) → default overwrite behavior → preset password (SecureField with Keychain save) → Finder auto-extract → safety policy summary → backend availability → completion.
  - The 7 "settings" steps show "Step N of 7" in the progress header; backup, version check, intro, completion are not counted.
  - Trigger: `AppPreferences.welcomeAssistantCompleted` controls the first-launch auto-pop; the SimpleZip menu adds "Run Welcome Assistant Again" so the user can replay it any time (without resetting the bool).
  - **Step 1 — Backup restore**: a JSON exported earlier from Settings → Backup & Restore can be imported on the spot, skipping later manual choices. Goes through `AppPreferences.importPayload` with the same schema validation, with the actual error shown on failure.
  - **Step 2 — Version check**: shows the currently installed version plus a button that opens Sparkle's standard update dialog.
  - **Backend step is now fully self-contained** (no more "Open Settings" punt). 7-Zip's "system" choice with no `7zz` on PATH inlines `brew install sevenzip` with Copy and Open-in-Terminal buttons (the Terminal button uses AppleScript to run the command automatically). RAR with `automatic`/`bundled` and no local backend offers an "Install Local RAR" button that opens the same `RarInstallReviewSheet` Settings uses — you must check off the LICENSE and README before the installer script runs. Already-installed local RAR exposes update / delete actions.
  - High-contrast status badge sits between the section title and the GroupBox, so "Ready" (green) vs "Unavailable" (orange) is readable at a glance instead of being hidden in a caption-grey description.
  - Cancel button is always visible at the bottom-left; clicking it raises a two-step confirmation alert (kept choices are preserved, the assistant can be re-opened later), preventing accidental dismissal.

- **New feature: Sparkle auto-update (unsigned / un-notarized)**
  - Wired [Sparkle 2.9.2](https://github.com/sparkle-project/Sparkle) via SPM. Info.plist gets `SUFeedURL` (pointing to `https://raw.githubusercontent.com/chiba233/SimpleZip/main/docs/appcast.xml`), `SUEnableAutomaticChecks`, `SUEnableInstallerLauncherService=NO`, and `SUScheduledCheckInterval=86400`.
  - Help menu gains a "Check for Updates…" item (Sparkle's recommended location), and the welcome assistant's Step 2 surfaces the same entry point.
  - `SparkleUpdater` singleton owns the `SPUStandardUpdaterController`; constructing it during `SimpleZipApp.init()` lets Sparkle's periodic check start as early as possible.
  - **Decision record**: this revision ships unsigned, un-notarized DMGs (there is no Apple Developer ID yet) and skips EdDSA update-package signatures. Sparkle still fetches the appcast, surfaces "new version available", and runs the download-and-replace flow; Gatekeeper will ask the user to right-click → Open to bypass the warning. If a community member ever donates a signing identity, the keys + notarization step slot in cleanly.
  - **release.yml** adds two new conditional steps that only run when the "Publish a GitHub release" path is taken (manual workflow with the box ticked, or a `v*` tag push): (1) write `docs/appcast.xml` containing the version, pubDate, GitHub Release download URL, and DMG byte size; (2) check out `main`, commit, and push so `raw.githubusercontent.com/.../main/docs/appcast.xml` updates immediately. A manual run that does not request a release leaves `main` untouched.

- **New feature: Favorites sidebar mirrors Finder**
  - The main window's left Favorites section is no longer 5 hard-coded entries (Home / Downloads / Desktop / Documents / Applications). It now mirrors the user's actual macOS Finder Favorites sidebar.
  - Data source: `~/Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.FavoriteItems.sfl4` (macOS 11+, sfl3 as a fallback), unarchived via `NSKeyedUnarchiver`. Each entry's `Bookmark` Data field is resolved with `URL(resolvingBookmarkData:)` to recover the underlying directory.
  - Display name comes from `.localizedNameKey` (so it follows the OS language — "Downloads" / "下载"), and the icon is mapped to an SF Symbol per known system directory (home / downloads / desktop / documents / movies / music / pictures / applications / iCloud Drive), defaulting to a generic folder for unknown paths.
  - Virtual Finder items (AirDrop, Recents, Tags) whose bookmarks don't resolve to real directories are filtered out; duplicate physical paths are de-duplicated.
  - **Sync trigger:** refreshes on `NSApplication.didBecomeActiveNotification` (main window regains focus). Editing the Finder sidebar and switching back to SimpleZip picks up the new state. Apple offers no official change notification for sfl4 — this is the closest reasonable touchpoint.
  - **Read-only:** SimpleZip never writes back to sfl4, so it cannot corrupt the Finder favorites. Reordering / adding directly inside SimpleZip is out of scope for this revision.
  - **Fallback:** if sfl4 is missing, parsing fails, or the user has never customized Finder favorites, the section falls back to the original 5 hard-coded entries instead of going blank.
  - **Persistent cache:** every successful read also writes the path list to UserDefaults. If a later launch hits a transient sfl4 failure (TCC, file lock, partial I/O), the sidebar still shows the previously good list instead of bouncing back to the hard-coded 5; cached paths are re-validated against the file system before being shown, so unmounted external volumes don't appear as dead links.
  - **Architecture notes:** `finderFavorites` lives on `ArchiveBrowserModel` as `@Published`, not on Sidebar's `@State`. The ObservableObject route survives the SwiftUI identity edge cases we hit inside `NavigationSplitView`'s sidebar column (where `@State` mutations on the main thread did not reach the next body evaluation). The Favorites section is rendered through a single ForEach over a uniform `FavoriteRow` array, sidestepping the rendering quirk we observed when the `if / else` arms in a `Section` produced heterogeneous tuple shapes.

- **New feature: create DMG archives**
  - The create-archive sheet now includes **DMG** as a macOS-native output option. DMG creation uses the system `hdiutil create -format UDZO` backend, so it does not depend on 7-Zip or RARLAB tools.
  - Multi-selection keeps the same top-level semantics as the other archive formats: SimpleZip stages the selected files / folders into a temporary folder first, then builds the DMG from that staging folder, so the DMG contains the selected items themselves.
- **DMG browsing fix**
  - Opening a `.dmg` file from inside another archive now works through SimpleZip's own DMG mount-and-browse flow. The extracted temporary DMG is mounted read-only and shown as a folder instead of being handed to `NSWorkspace`, which could fail or open outside the app's archive workflow.
  - Added a SwiftPM regression test that creates a DMG and lists it through the existing DMG backend.
- **Bug fixes**
  - **Sidebar pinned folders can now be managed more clearly.** Dropping existing folders onto the Pinned sidebar area adds them to the pinned list, keeps duplicates collapsed, and refreshes the sidebar immediately. Favorites no longer present a drop target because those built-in locations are not user-editable. Pinned rows now own their full-row context menu, so right-clicking a pinned folder reliably shows "Unpin".
  - **P1: header-encrypted archives failed at the pre-extract safety check.** `confirmArchiveExtractionSafety(archiveURL:)` called `ArchiveService.list` with an empty password, so header-encrypted 7z archives — where even enumerating entries needs the password — short-circuited the entire extract path and the user never reached the password retry loop. The safety check now takes a password / force, runs inside the retry loop (gated by a `didCheckSafety` flag so it only runs once after `list` succeeds), and first-pass `list` failures get caught by the outer password-prompt path. Combined with preset password + Finder auto-extract, header-encrypted 7z now works end-to-end.
  - **P2: preference "Import" was patch semantics, not "restore backup".** The old implementation only wrote the keys present in the payload, so any whitelist key the payload omitted kept its pre-import value — users importing a simpler backup ended up with leftover settings still applied. Import now wipes every whitelist key first (`defaults.removeObject(forKey:)`) so omitted keys fall back to the code defaults, then writes the payload values. The payload now represents complete state, not a diff.
  - **P2: Keychain write failures were masked by the in-process cache.** `PresetPasswordStore.save` ignored the `SecItemUpdate / SecItemAdd` OSStatus and updated the cache regardless, so a Keychain rejection (access denied, disk full, ad-hoc signing rotated) would show "Saved to Keychain" in the UI but the next launch's `load()` returned empty and the password silently vanished. `writeKeychain` now returns the real OSStatus, `save()` only updates the cache on `errSecSuccess`, `AppPreferences.setPresetPassword` returns a `Bool`, and `GeneralPane.savePresetPassword` shows the new `settings.presetPassword.saveFailed` message when the write didn't land (en + zh-Hans).
  - **Empty-space right-click menu showed items it shouldn't.** The old `menuNeedsUpdate` always built the full 15-item menu (Open / Open as Archive / Extract Here / Test / Hash / Copy / Cut / Paste / Move / Delete / Reveal in Finder), but `selectClickedRowIfNeeded` does nothing on an empty-space click — so right-clicking the blank area would surface "Test" / "Hash" with no selection to act on. The menu now branches on `tableView.clickedRow`: row-click keeps the full menu; empty-space gets just Paste + "Reveal current folder in Finder", matching Finder convention.
  - **0.1.6-dev: top menu bar didn't follow the in-app language picker.** `AppleLanguages` is read by AppKit *before* SwiftUI's `.commands {}` block is evaluated, so even after changing the in-app language and restarting, the native File / Edit / Window / Help / Hide / Quit menu items stayed in the OS language. The override is now applied in `SimpleZipApp.init()`, which runs before menu construction, so a relaunch picks up the chosen language end-to-end.
- **About panel**
  - The blurb has been rewritten to reflect what 0.1.6 actually does. Authored by Hoshino Yumeka.
  - Uses the standard macOS `orderFrontStandardAboutPanel` (so it follows the system theme / font sizes / margins instead of being hand-drawn). Credits stay deliberately short ("description + author") because the credits text view starts to scroll and grow a visible frame once the content overflows.
  - The repo URL and MIT License now live as native items in the Help menu (`SimpleZip Project Page` / `MIT License`) — that's the macOS-native way to surface app links, and avoids cramming them into the credits text.
- **Internal refactor: NativeZipBackend extracted (Phase 4 step 4)**
  - New `Core/Backends/NativeZipBackend.swift` (310 lines), absorbing every "system zip family" operation:
    - `list` — `unzip -l` + `tar -tf` outputs merged and parsed.
    - `test` — `unzip -t`.
    - `extract` — single entry point for ZIP files; internally picks an ordered list of backends (`[macOS, sevenZip]`) from the user's decryption preference plus the detected encryption header, falling forward when one fails.
    - `createTar` / `createTarGzip` — `tar -cvf` / `tar -czvf`.
    - `createZipFallback` — `/usr/bin/zip` fallback used only when 7zz is unavailable.
  - `ArchiveService` now forwards `.zipNative` / `.tar` / `.tarGzip` branches to NativeZipBackend in one line each; the `.zip` "7zz missing → native zip fallback" path goes through the backend too.
  - The legacy private helpers `extractZipArchive` / `extractZipArchiveWithSevenZip` / `extractZipArchiveWithMacOS` / `zipExtractionTools` / `zipExtractionToolName` plus the `ZipExtractionTool` enum are removed from `ArchiveService`.
  - After step 1 + step 2 + step 3a + step 3b + step 4, `ArchiveService.swift` is down from 1524 to 780 lines (cumulative **−744, −49%**). Next: step 5 extracts `RarBackend`, step 6 introduces the `ArchiveBackend` protocol and turns `ArchiveService` into a pure router.

- **Internal refactor: SevenZipBackend now owns the operations (Phase 4 step 3b)**
  - Moved all four 7-Zip operations — `list` / `extract` (whole archive + selective + flatten) / `test` / `benchmark` — out of `ArchiveService` and into `Core/Backends/SevenZipBackend.swift`.
  - The `.sevenZip` branches in `ArchiveService` are now one-line forwarders (`try await SevenZipBackend.xxx(...)`), and `ArchiveService.benchmark` delegates the whole body.
  - The private helper `extractZipArchiveWithSevenZip` (used when a zip file needs the 7-Zip path, e.g. AES-256 encrypted zips) now forwards too, so every "run 7zz to extract" call site goes through the same SevenZipBackend implementation.
  - The shared `OutputAccumulator` (the thread-safe string buffer used to feed live progress updates during benchmark) moves out of `ArchiveService` and into `SevenZipBackend` as a private type; `ArchiveService` no longer holds any 7zz operation-related state.
  - After step 1 + step 2 + step 3a + step 3b, `ArchiveService.swift` is down from 1524 to 973 lines (cumulative −551, **−36%**). Next: step 4 extracts `NativeZipBackend` (zip + unzip + tar), step 5 extracts `RarBackend`, step 6 introduces the `ArchiveBackend` protocol and turns `ArchiveService` into a pure router.

- **Internal refactor: SevenZipBackend extracted (Phase 4 step 3a)**
  - Moved the 7-Zip backend's discovery + metadata layer (bundled / system candidate paths, `resolve()` / `toolPath()` / `isAvailable()` / `backendDescription()` / `version()` plus the `ResolvedSevenZipTool` struct and `SevenZipToolSource` enum) into `Core/Backends/SevenZipBackend.swift` (136 lines). `ArchiveService.canUseSevenZip` / `sevenZipBackendDescription` / `sevenZipVersion` are now forwarders; the private `sevenZipTool` / `resolvedSevenZipTool` also forward (these thin wrappers will go away in step 3b once the `case .sevenZip` branches of list/extract/test move too).
  - Renamed the user-preference enums to clearer names: `SevenZipBackend` → **`SevenZipBackendChoice`**, `RarBackend` → **`RarBackendChoice`**. They represent a *choice*, not a *backend*; freeing up the original names for the actual backend implementation namespaces.
  - Shared path-discovery helpers (`applicationSupportDirectory` / `uniqueExistingCandidatePaths` / `envPath` / `cellarCandidates`) were broadened from `private` to `internal` so backend files in the same module can call them without round-tripping back through `ArchiveService`.
  - With step 1 + step 2 + step 3a complete, `ArchiveService.swift` shrunk from 1524 to 1007 lines (cumulative −517, **−34%**). Step 3b will move the actual list / extract / test / benchmark implementations into `SevenZipBackend`.
- **Internal refactor: BackendProcessRunner extracted (Phase 4 step 1)**
  - Extracted ~400 lines of process-running infrastructure (`runAndCapture` / PTY / cancellation registry / `ProgressOutputParser` / `InteractivePasswordResponder`) from `ArchiveService` into a stand-alone `BackendProcessRunner`. `ArchiveService.cancelRunningCommand` is now a thin forwarder.
- **Internal refactor: DiskImageBackend extracted (Phase 4 step 2)**
  - Moved the `.dmg` flow (mount / detach / list / extract / test plus the private `copyDiskImageContents` / `diskImageArchiveItems` / `DiskImageDateFormatter` helpers) out of `ArchiveService` into a focused `Core/Backends/DiskImageBackend.swift` (156 lines). The `case .diskImage` branches inside `list` / `extract` / `test` are now one-liners delegating to `DiskImageBackend.xxx`; the public `mountDiskImage` / `detachDiskImage` remain as forwarders so `ArchiveBrowserModel`'s "open DMG as folder" flow keeps working.
  - With step 1 + step 2 done, `ArchiveService.swift` shrunk from 1524 to 1071 lines (−453, −30%). Next: step 3 will extract `SevenZipBackend` (the biggest), step 4 `NativeZipBackend` (zip + unzip + tar), step 5 `RarBackend`, step 6 will introduce the `ArchiveBackend` protocol and turn `ArchiveService` into a pure router.
- **New feature: open any file as an archive**
  - The file-table context menu and the File menu now offer an "Open as Archive" command. Selecting a single non-archive file (`.exe`, `.apk`, `.ipa`, `.jar`, and other non-standard files that are really ZIP / NSIS / CAB inside) and triggering the command bypasses the extension check and hands the bytes straight to the 7-Zip backend, which sniffs the format from the file header.
  - The command is only enabled when the selection is exactly one non-directory file that isn't already a recognised archive, so it never duplicates the regular "Open".
  - Implementation: `ArchiveService` gained a `force` parameter that skips the extension → backend routing, and `ArchiveBrowserModel` tracks a `forcedArchiveURLs` set so list / extract / test calls that follow keep using the forced 7-Zip path. The set lives in memory only — opening the same file again after relaunch needs another right-click.
- **New feature: preferences backup & restore**
  - Settings gains a new "Backup & Restore" pane (7th sidebar item, ⇅ icon):
    - **Export preferences** → pick a destination and save a JSON file (default name `SimpleZip-Preferences-YYYY-MM-DD.json`, pretty-printed with sorted keys so it diffs cleanly and is easy to tweak by hand).
    - **Import preferences** → pick a file → confirm "your current preferences will be replaced, this cannot be undone" → write back.
    - **Restore all defaults** → a red destructive button with confirmation → clears every UserDefaults preference and removes the preset password from the Keychain.
  - **Allowlist-based export**: the exportable keys are registered explicitly (30+ of them). Private paths (last folder / pinned / recent sidebar) and sensitive fields (any leftover plaintext `presetPassword` from earlier dev builds) are never written to the export. Imports also only accept allowlisted keys, blocking malicious JSON from sneaking in OS-level keys such as `AppleLanguages`.
  - **Schema validation**: the JSON file must carry `schema: "SimpleZip.preferences"` and `version: 1`. Importing another app's plist, a future v2 file, or a payload with missing/wrong-type fields shows a precise error instead of silently writing garbage. Backed by 7 unit tests.
- **New feature: Health dashboard**
  - Settings gains a new "Health" pane (6th sidebar item, ❤️ icon): a single-screen view of the live status of the 7-Zip backend, RAR backend, file associations, and preset-password storage — green ✓ for OK, yellow ⚠ for warnings, red ✗ for outright failures, gray ⓘ for purely informational rows.
  - Each row carries a context-aware "fix" button when something needs attention: missing RAR → jump to the Archive pane to install the local copy, partial file-association ownership → jump to the File Associations pane, preset password enabled but empty → jump to General.
  - A "Re-check" button and a relative "Last checked …" timestamp sit at the bottom of the pane; the first time you open the pane it runs the checks automatically.
- **New feature: one-click diagnostics**
  - The long-task details panel and the operation-failure alert now offer a "Copy Diagnostics" button. Clicking it captures the app version, macOS version, bundled `7zz` / RAR backend paths + versions, operation title, start/finish times, error summary, and the tail of the command output (auto-trimmed to 4 000 chars with Chinese-aware boundaries) into a plain-text report that's ready to paste into a GitHub issue. The details panel shows a 2.5-second "Copied" confirmation.
  - The report **redacts** command-line password fragments (`-p<value>` / `-hp<value>` get replaced with `-p[REDACTED]` / `-hp[REDACTED]`) so users don't accidentally leak real passwords when pasting into a public issue. 11 unit tests pin the redaction rule and the report layout.
- **New feature: more startup-location choices**
  - The General → Startup location picker now includes the common macOS user folders (Documents, Movies, Music, Pictures) in addition to Home, Downloads, Desktop and "Last opened folder".
  - Picking "Add a custom location…" immediately opens a folder chooser, and afterwards the picker's collapsed label shows the folder's name (not the static "Custom location" label).
  - **Custom locations are now remembered**: every folder you pick is kept in an MRU list shown under the system folders, so you can switch between recent custom locations from the same menu. The total visible items are capped at 10; if you pick more, the oldest custom entries are evicted first — the system folders are never dropped.
  - Picking a location validates the folder exists; missing folders show a red "That folder isn't available right now" hint and self-prune from the MRU list without changing the current selection.
  - If the saved startup location is gone at app launch, an alert lets you choose "Open Settings…" (jump to General to repick) or "Reset to Home" (wipe the custom history and go back to home).
- **Bug fixes**
  - Fixed the Cmd+E menu silently switching to "Extract Selected" whenever items were selected inside an archive: the menu label says "Extract" (full archive) but the dialog that opened was the selection-only one. Cmd+E now always means full-archive extract; Cmd+Shift+E remains the dedicated "Extract Selected Items" shortcut.
- **Security / docs**
  - Added `SECURITY.md`: threat model (in/out of scope), vulnerability reporting channel (GitHub Security Advisories), the user-controllable safety policies, the at-rest / in-memory / on-screen security model of the preset password, and the bundled backend provenance and licenses.
  - Added `docs/release-checklist.md`: gating items before tagging a release (CI status, security-sensitive area regressions, localization completeness, version / CHANGELOG alignment, tag-push verification, DMG smoke test). The `release.yml` tag push goes through this list as the final gate.
  - README's "Documentation" section now links to SECURITY.md and the release-checklist.
- **New features: auto-extract from Finder + preset password**
  - General settings now includes "Auto-extract when opened from Finder": when on, opening an archive from Finder / Services / another app extracts it directly to the archive's folder, without opening the SimpleZip browser. DMG and other mount-style formats still go through the existing browse path. Safety prompts (path traversal / symlink / active content) still apply.
  - General settings now includes "Use a preset password": once configured and saved, creating an encrypted archive auto-fills the password, and opening / extracting password-protected archives tries the preset silently first, falling back to the password prompt only on failure. When both Finder auto-extract and preset password are on, the whole flow needs no further user confirmation.
  - Create-archive and extract dialogs gained a "Use preset password" checkbox that only appears when the preset feature is enabled in settings. It is checked by default; unchecking lets you type a one-off password.
- **Preset password is stored securely**
  - The password is kept in the macOS Keychain (`kSecAttrAccessibleAfterFirstUnlock`) — only SimpleZip can read or write it — and is no longer persisted as plain text in UserDefaults.
  - The settings input is a local buffer with an explicit "Save" button; closing the window without saving discards edits. Turning the master toggle off also wipes the Keychain entry.
  - Revealing the password (the eye button) requires local authentication (Touch ID or your Mac login). Background auto-fill / auto-try paths read silently — they don't prompt for Touch ID every time you extract.

- **Archive listing (bug fixes)**
  - Fixed a 7-Zip listing parser bug: the archive header block from `7zz l -slt` (containing `Path = <absolute path>`, `Type = 7z`, `Method = LZMA2:12`, `Solid = +`, etc.) was previously parsed as a regular entry, leaking the archive's own absolute path into the entry list and triggering ArchiveSafety's "absolute path" warning. Header blocks are now identified via the `Type` / `Physical Size` / `Headers Size` fields, which only appear in header blocks.
  - Fixed a bug where listing a password-protected archive returned an empty list: the password path uses a PTY, and macOS's default ONLCR converts `\n` to `\r\n`, but the parser did not normalize line endings, so the blank separator line between entries became `"\r"` and never triggered an entry flush, causing all entries' values to overwrite a single dict. CRLF normalization added at parser entry.
  - Both bugs were caught the first time the new pre-recorded fixture tests ran, which is the best demonstration of the fixture library's value (see the Tests section below).
- **Settings**
  - The Settings window is now resizable (min 720×520, ideal 820×560, no upper limit) instead of being locked to 820×560; Picker widths now adapt to the active translation so long labels are no longer clipped.
  - Fixed a bug in the Columns settings pane where the third row bound the archive "Size" toggle twice; that cell is now blank so the archive column count matches the real number of optional columns.
  - Removed an unused internal "set as default app" helper.
- **Internal refactor**
  - `SettingsView.swift` was split from a single 1448-line file into 14 focused files under `Features/Settings/` (GeneralPane / ArchivePane / BrowserPane / ColumnsPane / FileAssociationsPane / SevenZipBackendSection / RarBackendSection / RarInstallSheet, etc.), with Chinese "why this is written this way" comments to make future maintenance easier.
  - Shrunk `ArchiveBrowserModel.swift` from 2089 to 1744 lines (-345). Following `docs/ARCHITECTURE.md`, extracted three focused units: `ArchiveSession` (open-archive content + current path + synthetic directories + path expansion), `FileBrowserService` (folder listing, Finder-tag search, `FileItem` construction, location-bar completion), and `ArchiveOperationRunner` (one-at-a-time long task lifecycle: cancellation, ID tracking, child-process linkage).
  - Moved `NavigationLocation` and `MountedDiskImageSession` into a dedicated `BrowserNavigation.swift`.
- **CI / release pipeline**
  - Split the GitHub Actions workflow: the previous `build-dmg.yml` ran a full DMG build on every PR / push, wasting macOS runner minutes. It is now split into `pr.yml` (runs SwiftPM tests + Xcode Debug build on every PR / push, with SwiftPM scratch and derived-data caches, and PR runs are auto-cancelled on subsequent pushes) and `release.yml` (runs DMG packaging / GitHub release publish only on `v*` tag pushes or manual workflow_dispatch).
  - `release.yml` now derives the version from the tag name on tag pushes — pushing `v0.1.6` triggers an automatic release.
- **Tests**
  - Expanded the `ArchiveService` test suite from 27 to 84 cases. Added `ArchiveServiceArgumentsTests` (routing gates, argument-construction branches, command mapping, native-zip fallback conditions) and `ArchiveServiceParsingTests` (output-parsing edge cases, synthetic-directory expansion, ZIP encryption detection, CRLF line-ending normalization).
  - Introduced a pre-recorded regression fixture library at `Tests/SimpleZipCoreTests/Fixtures/` (plain / AES-256 / path-traversal cases for zip + 7z + tar, with Chinese filenames, nested directories, and empty directories), generated by `generate.sh` using macOS's `zip`/`tar`, the bundled `7zz`, and Python's `zipfile` (the script is re-runnable). The companion `ArchiveServiceFixtureTests` exercises the "read" path so tests no longer rely on "the same code wrote what the same code now reads" self-confirmation — the two 7-Zip parser bugs above were caught the first time this suite ran.

## 0.1.5

- **File associations**
  - Fixed setting RAR as the default app by using the stable `com.rarlab.rar-archive` type instead of also trying macOS's dynamic `.rar` UTI, and declared the RAR archive type in the app bundle.
- **Settings**
  - Added live column previews to the Columns settings pane so users can see how the file and archive lists will look before leaving Settings.
  - Reworked Settings into a left sidebar layout and split backend install actions into described rows instead of crowded button groups.
  - Moved the overwrite behavior default into General, added a General option to skip the delete confirmation prompt, and put the hidden-suffix disclosure control back on the left side of the row.
  - Added explanatory copy to the main Settings controls and grouped related options more clearly so users can understand what each choice changes before toggling it.
- **File operations**
  - Added a global "replace if different" overwrite preference and applied it across extraction merges, paste, drag-and-drop, and Move To Folder.
  - Broadened same-name conflict checks so regular files compare SHA256, symbolic links compare link targets, and folders compare recursive content fingerprints before deciding whether to replace.
  - Added an "apply to remaining conflicts" checkbox to same-name conflict prompts so large extraction, paste, drag-and-drop, and move operations no longer require answering the same question repeatedly.
  - Added a hash-conflict summary table for batch "replace if different" operations, showing which items matched and were skipped versus which items differed and were replaced.
  - Reworked the hash-conflict summary from a cramped alert table into a resizable SwiftUI panel with lazy scrolling and better truncation for long file names and hashes.
  - Fixed batch hash-conflict handling so SimpleZip shows either the single-file result or the batch summary, not both.
  - Hid empty hash-conflict summary sections so an all-skipped or all-replaced batch no longer leaves a misleading blank group.
  - Removed sticky section layout from the hash-conflict summary to avoid stray blank space before skipped items.
  - Split the hash-conflict summary comparison into separate existing-hash and incoming-hash columns.
  - Removed the low-value "Keep Both" choice from same-name conflict prompts so the dialog focuses on replace, skip, or replace-if-different.
- **Copy**
  - Reworded the delete confirmation to explain Trash recovery instead of mentioning implementation details.
- **Settings**
  - Cleaned up the Browser hidden-suffix controls so the collapsed row uses a normal setting height and the expand/remove/add buttons align with the rest of Settings.
- **Encrypted archives**
  - Fixed extraction of password-protected archives when the user leaves the optional password field blank: SimpleZip now prompts for a password and retries instead of failing immediately.

## 0.1.4

- **Finder integration**
  - Added a Finder Sync extension for right-click actions that calculate hashes and add selected files or folders to a new archive with SimpleZip.
  - Kept Finder Services as a fallback and added a `simplezip://` callback path so Finder actions can launch the app and open the existing hash or archive-creation flows.
- **Archive browsing**
  - Fixed numeric split archives such as `.001` / `.002` so the 7-Zip split-container record is no longer shown as a fake merged ZIP item inside the archive browser.
  - Fixed the Browser hidden-suffix master toggle so turning it off no longer disables the toggle itself and traps the setting off.

## 0.1.3

- **RAR backend**
  - Reworked the optional RAR creation backend so public builds no longer imply that the proprietary RARLAB `rar` binary is bundled with SimpleZip.
  - Renamed the RAR backend setting from bundled RAR to manual install, while preserving the existing preference value for compatibility.
  - Automatic and manual-install RAR modes now resolve the user-local Application Support backend first, then fall back to system-installed `rar` locations.
  - Added bundled RAR install assets: a license notice, README, and installer script. These ship with the app, but the RARLAB binary itself does not.
  - The RAR installer now downloads official RARLAB macOS packages and installs the universal `rar` backend to `~/Library/Application Support/SimpleZip/Tools/rar` instead of writing into the app bundle or repository tools directory.
  - Added an in-app review sheet that displays the RAR license notice and README, requires separate "I have read" confirmations for both documents, and only then enables download/install or update.
  - Added Settings actions to install, update, reveal install files, open the README, and delete the local RAR backend plus copied RARLAB notices.
  - Fixed the RAR system-installed backend setting so it only shows the Homebrew install command when missing, instead of also showing the local installer-script controls.
  - Updated the unsigned DMG packaging script to reject app bundles that accidentally contain the proprietary RARLAB backend unless explicitly allowed for a build with redistribution rights.
  - Added Xcode project resource exclusions so ignored local RARLAB binaries and notices are not copied into the app bundle by file-system synchronized groups.

## 0.1.2

- **Archive browsing**
  - Unified the main toolbar buttons, settings forms, bottom action rows, and file-association controls so Release builds no longer show as many mismatched button and field sizes.
  - Fixed the GitHub CI `ArchiveTable` file-promise export path so it no longer captures the main-actor-isolated `model` from a nonisolated context, which was breaking Xcode 16.4 Release builds.

## 0.1.1

- **Assets**
  - Added a generated macOS app icon set from the provided project artwork and wired it into `AppIcon.appiconset`.
  - Swapped in a new icon source, removed the outer checkerboard background, cropped away the excess blank margins around the artwork, and regenerated the app icon set plus `AppIcon.icns`.
  - The About panel now uses the real application icon instead of the template fallback.
  - Refined the icon masking so the crop follows the main icon body without cutting into the artwork inside it.
  - Regenerated the full app icon set and bundled `AppIcon.icns` from the latest desktop artwork by stripping the edge-connected dark background into transparency.
  - Scaled the icon artwork back into a macOS-style safe area so it no longer appears visually larger than neighboring apps in the Dock and Finder.
- **Archive browsing**
  - Archive directories are now presented as real navigable folders instead of flat path rows.
  - Double-clicking a file inside an archive now extracts that item to a temporary location and opens it with the default macOS app.
  - Archive rows can now be dragged out to Finder or other file destinations; SimpleZip extracts the promised items directly to the drop location.
  - Synthetic directory nodes are generated when an archive does not explicitly store directory entries.
  - Double-click and context menu opening are supported inside archive folders.
  - Archive browsing now uses richer per-entry file icons and adds a Kind column, so the archive list is closer to the regular file browser instead of a bare generic list.
  - Local `.app` and other macOS packages now open like applications by default, use their package icons, and offer Show Package Contents from the context menu.
  - The location bar now offers folder autocomplete while typing, with a scrollable dropdown, total match count, keyboard navigation for Up/Down, Tab completion, and Return to open the highlighted folder.
  - Opening an archive no longer eagerly asks for a password just to browse its contents; password authentication is now deferred to the moment an encrypted entry is actually opened from inside the archive.
  - The Browser settings pane now includes a Show symbolic-linked files and folders toggle, and folder/tag browsing plus folder autocomplete honor it immediately.
  - Added a Browser toggle to make folders follow Finder structure; all folders now go through the same Finder-aligned listing path, and special macOS app directories such as `/Applications` and `Utilities` can merge the relevant system app locations without changing the default view.
  - Tightened the Finder-structure `/Applications` merge so it no longer dumps the hidden CoreServices helper apps into the main Applications view; Finder itself is still surfaced explicitly where Finder shows it.
  - Fixed local `.app` bundles in the file browser so their Application column no longer reuses the wrong third-party handler for every app bundle just because they share the `.app` extension.
  - Added a Browser drawer for hidden name suffixes, with recommended macOS package suffix toggles plus custom suffix entries so names like `.app` can be hidden without changing the real file path.
  - Added a root toggle for hidden suffix display and fixed the custom-suffix Add button so it enables correctly whenever the typed suffix is valid and not already configured.
  - Merged the hidden-suffix root switch into the same row as the hidden-suffix drawer so the setting reads as one control instead of two stacked labels.
  - Made the custom hidden-suffix input look like a real input field, with a visible text box and prefix dot so it no longer blends into plain settings text.
  - Opening a single encrypted item from an archive now front-loads the password prompt when the archive metadata already indicates encryption, instead of first waiting for backend extraction failure timeouts.
- **Extraction**
  - ZIP extraction now exposes a decryption method selector for Auto, ZipCrypto, AES-128, AES-192, and AES-256; Auto tries the common compatible paths so encrypted ZIP files from other tools do not get stuck on macOS `unzip`.
  - Auto ZIP decryption now shows the detected archive encryption algorithm, and the password/decryption controls have clearer spacing.
  - Operation details output now scrolls horizontally and vertically so long backend error lines do not overflow the details window.
  - Fixed 7-Zip passworded ZIP extraction by no longer passing a bare `-p` flag that 7-Zip interprets as an empty password during extraction.
  - Extraction failures now always surface properly: without Show Details they raise the Operation Failed alert and still preserve full backend output behind the Details button; with Show Details enabled they stay in the details sheet without spawning a duplicate alert window.
  - Archive operation failure alerts now use a shared preview model, so long backend output is truncated only in the alert while the full message remains available in Details.
  - Shared the common whole-archive and selected-entry extraction options form so destination, password, details, and action controls stay consistent.
  - Extraction now stages files in a temporary directory before merging, so existing destination files always go through SimpleZip's conflict dialog instead of being overwritten by the backend.
  - Whole-archive and selected-entry extraction now support an optional password field.
  - Double-clicking an encrypted file inside an archive now prompts for a password only when extraction/opening actually needs it, and ZIP prompts also expose the decryption-method selector used by the extraction flow.
  - Long-running extraction now reports progress and the current file when the backend emits progress output.
  - Even without Show Details enabled, the status bar now shows the current file plus completed/total item counts during archive operations instead of only a bare progress bar.
  - Added a Show Details option for extraction so the live command output can be opened in a details sheet and reopened from the status bar to inspect skipped files, symlink handling, and other backend messages.
  - Selected archive extraction now defaults to the archive's containing folder and only changes destination when requested.
  - Whole-archive extraction now also opens its options sheet first and only changes destination when Save To is clicked, instead of immediately opening a Finder destination panel.
  - Selected archive extraction supports keeping folder structure or flattening files into the target folder.
  - The main toolbar Extract action now automatically switches to Extract Selected when items are selected inside an archive.
  - ZIP selected-entry extraction uses macOS `tar` path listing/extraction to avoid `filename not matched` mismatches from `unzip`.
  - Directory selection expands to child entries before extraction.
  - Extraction merge now honors the default overwrite preference when destination files already exist.
  - The overwrite preference now includes Ask, so extraction can always fall back to the conflict dialog instead of silently replacing or skipping files.
  - Passworded archive operations now avoid passing passwords on the command line.
  - Password prompt handling now fails with a clear error and terminates the backend process if the backend asks for more password responses than SimpleZip can provide.
- **Archive creation**
  - Long-running archive creation now reports progress and the current file when the backend emits progress output.
  - Added a creation options sheet.
  - Added a Show Details option for archive creation so the live command output can be inspected during compression instead of being collapsed into the status line, and moved the toggle into the lower-left action area.
  - The lower-left Show Details control in the Add to Archive sheet is now rendered as an explicit button-style toggle so it is harder to miss.
  - Archive creation and extraction now share the same button-style Show Details control component, so the two sheets no longer drift in appearance or placement.
  - Expanded the 7-Zip creation sheet with dictionary size, word size, solid block size, path mode, symlink/hard-link storage, shared-file compression, and delete-after-compression options to better match desktop archiver workflows.
  - Added an archive file name field so the output name can be edited without opening the save panel.
  - ZIP, 7z, TAR, GZ, TGZ, BZ2, and XZ creation are selectable.
  - Added compression level selection.
  - Added optional password input.
  - Added `.DS_Store`, dotfile, and custom exclude rules, and TAR/TGZ creation now honors those filters too.
  - Archive creation now counts files before starting, shows a loading indicator during counting, and switches to determinate progress once the total is known.
  - Long-running archive commands can now be cancelled from the status bar.
  - Cancelling a running operation now targets the command process registered for that operation instead of relying only on a single global active process.
  - Archive command cancellation now passes operation identifiers explicitly instead of using a shared scope slot, avoiding cross-operation process registration when operations overlap.
  - Backend processes that ignore graceful termination now receive a SIGKILL fallback after a short timeout.
  - While an operation is running, the status bar now stays compact: indeterminate spinner mode no longer reserves a wide empty slot, and inline file-log text has been removed in favor of the Details sheet.
  - ZIP archives now support split-volume creation when a volume size is set, and GZ/BZ2/XZ creation now blocks invalid multi-file selections before the command starts.
  - Dotfile exclusion now explains that files like `.env`, `.gitignore`, and `.npmrc` are also skipped.
  - Dotfile exclusion is no longer enabled by default, so files such as `.env` and `.gitignore` are preserved unless the user opts in.
  - Custom exclude options now include a manual Calculate action that scans the selected sources and reports how many files will be excluded.
  - Invalid split-volume sizes, password mismatches, missing RAR backends, and single-file-only format mistakes now show inline validation messages in the Add to Archive sheet.
  - Format, compression level, and update mode controls now sit on one compact row in the Add to Archive sheet.
  - The Add to Archive window is compact again: password controls now expand only when needed, 7-Zip advanced options are collapsible, and the sheet no longer grows to an oversized height.
  - RAR creation now probes bundled, application-bundled, and system `rar` binaries instead of only one path, and shows a clear disabled-state message when no RAR backend is available.
- **Reliability**
  - Added a GitHub Actions workflow and local script for building an unsigned, ad-hoc signed macOS app DMG artifact without requiring a Developer ID certificate.
  - The unsigned DMG workflow can now be manually published as a GitHub Release with a chosen app version.
  - The unsigned DMG workflow now installs and verifies the bundled RAR backend before packaging.
  - Split `ArchiveService` argument building and archive parsing helpers into dedicated core files, reducing the size of the main backend facade without changing its public API.
  - Centralized archive-operation success/failure cleanup in `ArchiveBrowserModel`, reducing repeated post-operation refresh and alert/detail state handling.
  - Fixed `scripts/build_unsigned_dmg.sh` so `set -u` no longer breaks CI when release-version build settings are absent.
  - Marked the archive/file table coordinators as `@MainActor`, fixing stricter Xcode CI builds that rejected menu, selection, and drag/drop callbacks touching `ArchiveBrowserModel`.
  - Added a visible Xcode `SimpleZipCoreTests` target that runs the SwiftPM core regression suite.
  - Expanded core tests to cover command-line argument splitting, volume-size validation, custom excludes, exclude counting, and RAR creation arguments.
  - Added core regression coverage for archive-operation failure alert preview truncation.
  - Added startup cleanup for stale temporary directories created when opening archive entries as external temporary copies.
  - Added active safety confirmations for suspicious archive paths, extracted symbolic links, and executable or active-content items opened from temporary archive copies.
  - Added Archive security settings so suspicious paths, extracted symbolic links, and active-content opening can each be set to Ask, Always Allow, or Always Block.
  - Extraction merging now validates that staged source files stay inside the staging directory and final targets stay inside the chosen destination directory.
  - Extraction merge containment now also checks resolved paths for ordinary staged files/directories and destination parent folders, while preserving explicit symlink handling.
  - Documented the current security model, archive compatibility matrix, progress limitations, and architecture refactor boundaries.
  - Cleaned up Swift concurrency warnings in the archive command runner and added a shared Xcode run scheme that hides OS activity noise during debug launches.
  - Backend path detection no longer launches `which` during Settings rendering, avoiding main-thread `Process.waitUntilExit()` stalls.
  - DMG mount and detach operations now run through the async command path so opening disk images does not block the main thread.
  - Header context menu column settings now open the SwiftUI Settings scene through the app's settings-opening path and defer tab selection to avoid state updates during view refreshes.
  - Archive table sorting now uses raw size and modified-date values instead of sorting localized display text.
  - Stale archive and tag loading tasks are now cancelled before newer results update the UI.
  - Drag-and-drop URL collection and external file open queuing are now synchronized to avoid callback races.
  - Split archive opening now normalizes `.001/.002`, `.z01`, `.r00`, and `part02.rar`-style inputs to the correct first volume automatically.
  - DMG files can now be opened by mounting them through `hdiutil`, and whole-image extraction now copies mounted contents out through the existing extraction flow.
  - Added service-layer regression tests for archive list parsing, exclude pattern generation, and selected-entry expansion.
  - Cleared Swift concurrency and optional-handling build warnings in archive parsing, progress parsing, and About panel icon wiring.
- **File browser**
  - Added Back and Forward navigation buttons next to the path bar, separate from the existing Go Up action.
  - Archive creation and extraction now refresh the visible destination folder automatically when the operation finishes.
  - Shared the common AppKit table setup, column configuration, cell rendering, and column-settings menu helpers used by the file and archive tables.
  - File rows can now be dragged onto folders in the file table to move local files, or dropped in from external locations to copy them into the current folder.
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
  - File browser columns now cover more Finder-style metadata, including Kind, Application, Last Opened, Date Added, Modified, Created, and Size.
- **File associations**
  - Settings now show a per-extension association list.
  - Each supported archive extension can be set as default individually.
  - Current default app is displayed per format.
  - RAR and DMG are now included in the association list.
  - Finder document-type declarations and default-app settings now include common split archive volume extensions like `.001`, `.z01`, and `.r00`, so split archives can be handed to SimpleZip from Finder.
- **Hashing**
  - Added CRC32, MD5, SHA1, SHA256, and SHA512 reports.
- **Menus**
  - Added functional macOS File menu actions for opening, creating, extracting, testing, hashing, revealing, refreshing, and navigating.
  - Added Edit menu commands that use file operations when the file table is active and fall back to native text editing actions elsewhere.
  - Moved the refresh button next to the up-navigation button so both directory navigation actions stay together.
  - File, archive, and column-header context menus now show action icons, and the main command menus use matching labeled icons for common actions like delete, move, extract, and reveal.
- **Settings**
  - Settings are now separated into General, Archive, Browser, File Associations, and Columns tabs.
  - Added language selection.
  - Added 7-Zip backend selection for Automatic, Bundled, and System binaries with version display.
  - Added matching RAR backend selection for Automatic, Bundled, and System binaries with resolved-path and version info.
  - Bundled backend display now clearly labels whether the resolved binary is bundled or system-provided.
  - 7-Zip backend detection now searches bundled paths, common Homebrew paths, Homebrew `opt` and `Cellar` folders, and PATH.
  - Settings now keep the startup folder, overwrite behavior, hidden-file visibility, and column visibility preferences; the extract destination default has been removed because extraction already starts in its options sheet.
- **7-Zip backend**
  - Bundled official 7-Zip 26.01 universal macOS `7zz` binary with `x86_64` and `arm64` slices.
  - Added bundled 7-Zip license and readme files to app resources.
- **RAR backend**
  - Added a local installer script that downloads the official RARLAB macOS ARM and x64 packages, creates a universal `SimpleZip/Tools/rar`, and keeps the proprietary backend ignored by git.
  - Documented the RARLAB redistribution caveat for local packaging.
- **Localization**
  - Added English, Simplified Chinese, Traditional Chinese, Japanese, and Thai strings.
  - Added Spanish, French, German, Korean, and Russian localizations, and exposed them in the in-app language picker.
  - Missing strings in selected language bundles now fall back to the bundled English strings instead of surfacing raw localization keys, and duplicate English keys were cleaned up.
  - Completed the missing security, navigation, and password-error strings across all bundled localizations.
- **Docs**
  - Added README, Chinese guide, changelog, contribution guide, and license files.

## 0.1.0

- Initial SimpleZip prototype:
  - macOS SwiftUI shell;
  - folder browsing;
  - basic ZIP open/create/extract flow;
  - About panel and project page metadata.
