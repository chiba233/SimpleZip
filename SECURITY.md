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
