# Release Checklist

Use this before tagging a SimpleZip release. The goal: every item is either
checked off or has a documented reason to skip in the PR description.

References:
- CI workflows: `.github/workflows/pr.yml` (PR / push checks),
  `.github/workflows/release.yml` (tag push or manual workflow_dispatch).
- Threat model: [`SECURITY.md`](../SECURITY.md).
- Architecture: [`docs/ARCHITECTURE.md`](./ARCHITECTURE.md).

---

## 1. Code on `main` is green

- [ ] `pr.yml` is passing on the latest `main` commit.
- [ ] `swift test --scratch-path /private/tmp/SimpleZipSwiftPM` passes locally.
      Should be ≥84 cases — fewer means tests were silently dropped.
- [ ] `xcodebuild -project SimpleZip.xcodeproj -scheme SimpleZip -configuration Debug build`
      passes locally (catches Xcode-only target issues that SwiftPM misses).
- [ ] Tests added or updated for any new business logic in this release.
- [ ] Fixture library still valid: if any `parseSevenZipList` /
      `parseUnzipList` / `detectZipEncryption` / `ArchiveSafety` change
      happened, the corresponding `ArchiveServiceFixtureTests` cases
      were updated to match.

## 2. Security-sensitive areas reviewed

- [ ] Any change to `ArchiveSafety` retains existing unsafe-name detection
      (path traversal, absolute paths, Windows drive paths, UNC paths).
- [ ] Any change to symlink / hardlink extraction paths still surfaces a
      confirmation in **Ask** mode and blocks in **Always block** mode.
- [ ] Any change to **active content** detection still catches
      `.app`, `.pkg`, `.command`, `.sh`, `.scpt`, scripts, HTML, Office files.
- [ ] Any change to the `passwordResponses` / PTY input path keeps passwords
      off the command-line arguments.
- [ ] Any change to `PresetPasswordStore`:
  - keeps `kSecAttrAccessibleAfterFirstUnlock` (not `WhenUnlocked`, not
    no-attr — both reduce reliability across reboot scenarios);
  - keeps Touch ID gate for "show password" on the settings UI;
  - keeps process-cache invalidation on `clear()` / `save()`;
  - does **not** add accidental logging of the password value.
- [ ] If a new feature introduces a new file-handling code path,
    add an entry to `SECURITY.md` "User-Facing Security Controls" or
    "Threat Model" sections.

## 3. Compatibility regression

- [ ] Manually verify on a clean macOS user account (or new VM):
  - open a representative `.zip`, `.7z`, `.tar`, `.tar.gz`, `.rar`,
    `.dmg`;
  - extract a password-protected ZIP (AES-256) and a header-encrypted 7z;
  - create a multi-volume 7z (e.g. `-v64m`);
  - calculate a hash of a folder.
- [ ] Finder integration: right-click on a folder → SimpleZip → "Add to
      archive" works, and right-click on an archive shows expected actions.
- [ ] If preset password is enabled in this build:
  - Touch ID reveal still works on a Touch-ID-equipped Mac;
  - login-password fallback works on a Mac without Touch ID;
  - turning the master toggle off still wipes the Keychain item
    (verify with **Keychain Access.app**).

## 4. Localization sanity

- [ ] New `Localizable.strings` keys exist in all 10 lproj directories.
  (When in doubt: `comm -23 <(grep -oP '\"[^\"]+\"\s*=' en.lproj/Localizable.strings | sort) <(grep -oP '\"[^\"]+\"\s*=' zh-Hans.lproj/Localizable.strings | sort)` should be empty.)
- [ ] No untranslated English strings appear when the app runs with
      another language set as the active locale.

## 5. Versioning and CHANGELOG

- [ ] `Info.plist` `CFBundleShortVersionString` matches the release version.
- [ ] `CHANGELOG.md` and `CHANGELOG.zh-CN.md` both have a `## <version>`
      section that lists the user-visible changes, not just code reshuffles.
- [ ] Internal refactors are summarized under an "Internal refactor" subsection
      so users can skip them.
- [ ] Bug fixes carry enough context to be searchable by symptom
      ("password-protected list returned empty" not "fix parser").
- [ ] `README.md` highlights / formats list updated if a new format
      gained support.

## 6. Cut the release

- [ ] On `main`: tag with `v<version>` (`git tag -s v0.1.6 -m "..."`
      if signing keys are configured; `-a` otherwise).
- [ ] Push the tag: `git push origin v<version>`.
- [ ] `release.yml` triggers; verify the workflow run:
  - SwiftPM tests pass (last defence before packaging);
  - RAR backend install step succeeds;
  - DMG artifact uploaded as `SimpleZip-unsigned-dmg`;
  - GitHub release auto-created with the DMG attached and the
    "unsigned" warning notice.
- [ ] If the workflow fails on the tag run, delete the tag (`git push --delete
      origin v<version>`), fix on `main`, and re-tag.

## 7. Post-release

- [ ] Smoke-test the published DMG by downloading it from the GitHub release
      and opening on a clean Mac:
  - Gatekeeper warning appears (expected: unsigned build);
  - app launches after right-click → Open;
  - bundled `Tools/7zz` is found by the binary inside the .app;
  - the version shown in About matches the tagged version.
- [ ] Watch the issue tracker for the next 24h for first-launch reports.
- [ ] If something is broken, prefer publishing `v<version>.1` over editing
      the existing tag — tags are not supposed to move.

## 8. Things that are **not** required for an alpha-grade release yet

These are tracked, but are not gating conditions today; flip them to required
items when each lands:

- Developer ID signing + notarization (Phase 11 candidate; tied to Sparkle).
- Sparkle update feed (Phase 11; user has not confirmed appcast hosting).
- Public security mailbox separate from GitHub Advisories.
- Reproducible builds.
