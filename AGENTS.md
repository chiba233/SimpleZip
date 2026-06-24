# Repository Instructions

These instructions are for AI agents working in the SimpleZip repository.

SimpleZip is a native macOS archive manager written in Swift and SwiftUI. Treat archive handling, filesystem operations,
temporary extraction, backend command construction, app associations, and CLI/app bundle behavior as security- and
data-safety-sensitive.

## Response Language (回复语言)

**Always reply to the user in Chinese (简体中文).** This applies to every conversational turn — explanations, status
updates, questions, summaries — regardless of the language of the code, file contents, logs, tool output, or this
document. This rule survives context compaction: after any summary or `/compact`, keep replying in Chinese; do **not**
revert to English. (Code, identifiers, commit messages, CHANGELOG entries, and `L10n` keys still follow their existing
per-file conventions — this rule governs only the chat replies to the user.)

始终用简体中文回复用户。这条在 compact / 上下文摘要之后依然有效,绝不因为总结过就切回英文。

## Start Here

Before changing files:

- Identify the smallest edit that satisfies the user's literal request. Do not expand scope, redraw UI, or bundle cleanup
  with a bug fix unless the user explicitly asks.
- Check whether the touched area has an existing pattern. Prefer one more row, toggle, branch, or helper in the current
  flow over a parallel service, view, sheet, or model.
- Protect user data. Archive paths, extraction targets, temporary directories, symlinks, hardlinks, delete/move/merge
  flows, and backend command arguments are high-risk surfaces.
- Preserve user work. Do not overwrite unrelated working-tree changes, and never rewrite git history.
- For user-visible UI text, use `L10n.text("some.key")` and update both `en.lproj` and `zh-Hans.lproj`.
- For business code changes, run the smallest relevant real verification before finishing and report exactly what ran.
- For documentation-only changes, skip lint/test/build unless the doc update depends on a fresh command result.

## Hard Rules

- Never use `git reset --hard`, history-dropping `git reset`, `git revert`, `git commit --amend`, `git rebase`,
  `git push --force`, or tag deletion/movement. Commits are append-only.
- Do not touch `MARKETING_VERSION`, `CURRENT_PROJECT_VERSION`, `CFBundleShortVersionString`, or `CFBundleVersion` for a
  normal version bump. CI owns build-time versions.
- Do not silently overwrite user data during extraction, merge, move, delete, or open workflows.
- Do not pass passwords or sensitive values through visible command-line arguments when an existing safer mechanism is
  available.
- Do not add half-wired selectors, menu actions, model calls, or references. If a symbol is named, the project must compile.
- Do not modify tests by default. Diagnose and fix production code first; ask before changing tests that appear outdated.
- Do not fabricate verification results. If a command did not run, say it did not run.
- Do not stop, end the turn, or ask "should I continue?" while the requested task still has unfinished, unblocked work —
  above all the AI whitepaper (`docs/AI-IMPROVEMENT-SUGGESTIONS.md`, task #80). Keep going commit-by-commit until the work
  is genuinely complete or genuinely blocked on a decision only the user can make. A verified milestone, a long turn, or
  "this is a clean checkpoint" is NOT a reason to stop. See A23.

## Project Map

- SwiftPM package: `Package.swift`
- Core library target: `SimpleZipCore`
- Core source: `SimpleZip/Core`
- App target source: `SimpleZip/App` and `SimpleZip/Features`
- Finder extension source: `SimpleZipFinderExtension`
- Tests: `Tests/SimpleZipCoreTests`
- Architecture notes: `docs/ARCHITECTURE.md`
- Bundled backend: `SimpleZip/Tools/7zz`

SwiftPM intentionally excludes the app UI, app assets, localizations, and tools from `SimpleZipCore`. Changes in
`SimpleZip/Core` should normally be covered by SwiftPM tests. Changes in app UI, assets, localization, Finder extension,
Xcode project settings, build settings, or app bundle behavior should also be verified with an Xcode Debug build.

## Verification

For any business code change, always run the smallest relevant real verification before finishing.

Lint: SwiftLint, **local dev tool only — not run in CI**. Run before finishing any business Swift change:

```bash
npm run lint           # = scripts/lint-changed.sh
```

- Lints only the **lines changed** vs `main` (config `.swiftlint.yml`). Historical code is never touched, so
  the repo's pre-existing violations don't drown out genuinely new ones. Portable (no baseline — SwiftLint's
  baseline stores absolute paths and is useless across machines/CI). New files are linted in full.
- Fix new violations in code; `swiftlint --fix` auto-corrects the fixable subset.
- SwiftLint needs sourcekit from a full Xcode. The npm wrapper sets `DEVELOPER_DIR` automatically; running the
  script directly under Command Line Tools aborts with `Loading sourcekitdInProc.framework … failed` — prefix
  with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` (or your Xcode path).
- Requires the `swiftlint` binary (`brew install swiftlint`, or `npm run install`). If it is genuinely
  unavailable, say lint was not run because the tool is missing — do not invent a lint result.

Default SwiftPM core tests:

```bash
/usr/bin/env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcrun swift test --scratch-path /private/tmp/SimpleZipSwiftPM -Xswiftc -module-cache-path -Xswiftc /private/tmp/SimpleZipSwiftPM/ModuleCache
```

Xcode Debug build for app-impacting changes:

```bash
/usr/bin/env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcodebuild -project SimpleZip.xcodeproj -scheme SimpleZip -configuration Debug -derivedDataPath /private/tmp/SimpleZipDerivedData build
```

UI launch smoke tests (XCUITest target `SimpleZipUITests` — app launches, a window and the menu bar
appear, app terminates). Optional but cheap; run when an app-target change could affect launch / window /
menu assembly:

```bash
/usr/bin/env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcodebuild -project SimpleZip.xcodeproj -scheme SimpleZip -destination 'platform=macOS' test
```

They launch the real `SimpleZip-dev.app`, so they need a window server (not headless) and the local `SimpleZip Dev`
signing identity (CI would need its own signing). Not wired into `pr.yml` — run locally before a release.

Use this matrix:

- Core logic only, especially `SimpleZip/Core`: run the SwiftPM core tests.
- App UI, SwiftUI views, menus, window behavior, assets, localizations, app target files, Finder extension, Info.plist,
  entitlements, Xcode project, dependency versions, or build settings: run SwiftPM core tests and the Xcode Debug build.
- Documentation-only changes such as `README.md`, `AGENTS.md`, `CHANGELOG.md`, `docs/*.md`: skip lint/test/build unless
  the doc update depends on reporting a fresh command result.

Final responses after business code changes must include:

- lint result: `npm run lint` passed / failed, or why it was not run (e.g. tool missing);
- test/build command run;
- whether each command passed, failed, was blocked, or was not executed;
- any residual risk if verification was partial.

For documentation-only changes, state that verification was intentionally skipped because only non-business files were
changed.

## Coding Rules

- Prefer clear Swift types over force casts, force unwraps, broad type erasure, ad hoc dictionaries, or stringly typed
  state.
- Do not use `as!` unless there is a proven invariant and no safer boundary is practical.
- Avoid `try!` and `fatalError` in production code. Use typed errors, throwing functions, user-visible alerts, or logged
  failures as appropriate.
- Avoid implicitly unwrapped optionals in new code unless required by a framework lifecycle boundary.
- Keep async work cancelable where it represents user-triggered archive, filesystem, or hashing operations.
- Keep UI state mutations on the main actor. Do not update SwiftUI-observed state from background tasks.
- Do not introduce silent fallbacks such as empty strings, empty arrays, `nil`, or default URLs to hide failures.
- Do not change user-visible behavior merely to satisfy a test. Preserve the archive manager workflow unless the requested
  change explicitly alters it.

## macOS UI Rules

- Follow existing SwiftUI and AppKit interop patterns in `SimpleZip/App` and `SimpleZip/Features`.
- Keep views focused on presentation and user interaction. Move backend calls, filesystem work, parsing, and command
  argument construction into services or models.
- Do not block the main thread with backend processes, filesystem scans, hashing, archive listing, extraction, or DMG
  mounting.
- Use native macOS controls and conventions for menus, sheets, settings panes, alerts, table behavior, drag-and-drop,
  and keyboard commands.
- When changing localized UI text, update all relevant `.lproj` files or explicitly state which localizations still need
  follow-up.

### Design System (0.4.3+) - compose UI from the component library

The app has a small in-repo design system. Hand-built custom dialog/panel UI is allowed and expected when it is composed
from these components and follows their conventions. Bypassing the library is a regression.

- Dialog skeleton: `TaskDialogShell` (hero + capped scroll content + pinned footer in one declaration). Standard
  confirm dialogs must use it; report-style (close-only / toolbar-style) footers use `PinnedBottomBar` directly.
- Pieces: `DialogHero`, `DialogSection` (card), `DialogDrawer` (collapsible card), `DialogRowLabel` (colored tile +
  title), `DialogToggleRow`, `IconTile` (the one tile implementation - solid for rows, gradient for heroes/drawers;
  settings rows add `.saturation(0.75)` on top), `DialogFooter`, `dialogFieldEmphasis()`. Settings panes use
  `SettingsControlRow` / `SettingsToggleRow`.
- Layout rules: row values (paths / fields / pickers / menus) pin to the trailing edge via
  `label + Spacer(minLength: 12) + value`. Do not use `LabeledContent` in plain VStacks because it does not fill the
  width and produces ragged right edges. Path texts hug their Choose buttons
  (`.frame(maxWidth: .infinity, alignment: .trailing)`). Input fields share their label's row. Captions/hints span the
  full row below, hugging their control with spacing 6. Long explanatory paragraphs live outside cards as footnotes
  (indent 14). Never fake alignment with empty-label spacer rows. Checkboxes never sit left of their text.
- Still native-first for behavior: system menus, alerts, open/save panels, drag sessions, keyboard handling. The
  relaxation covers visual composition, not re-implementing system furniture.

## Archive and Filesystem Safety

Archive contents are untrusted input. Be conservative around paths and backend output.

- Preserve and extend existing protections for path traversal, absolute paths, Windows drive paths, UNC paths, symlinks,
  hardlinks, executable content, package bundles, temporary extraction, and conflict handling.
- Keep suspicious archive entry handling explicit and user-visible.
- Keep temporary resources scoped and cleaned up through `TemporaryResourceManager` or the existing owner for that flow.
- Use `FileManager.default.temporaryDirectory.appendingPathComponent("SimpleZip-...-\(UUID().uuidString)")` for scratch
  directories. Do not write scratch data into project directories, Documents, or hard-coded ad hoc locations.
- Be careful with 7-Zip full path mode, symlink preservation, hardlink preservation, DMG mounting, and archive entries
  that may escape the visible folder tree.
- When changing backend argument construction, add or update production coverage where possible and verify the exact
  arguments being generated.

## Architecture Guidance

- Read `docs/ARCHITECTURE.md` before large refactors.
- Keep `ArchiveBrowserModel` as UI-facing state where possible; avoid adding more backend or filesystem ownership to it.
- Prefer moving pure archive logic into `SimpleZip/Core`, where it can be tested by SwiftPM.
- Keep `ArchiveService` as the backend facade until a deliberate backend split is made.
- Avoid broad refactors mixed with feature fixes. Move one ownership boundary at a time.
- Follow existing naming, file organization, and model patterns before introducing new abstractions.

## Maintainer Appendix: Common Anti-Patterns

These are rules earned from real corrections. Follow the rule before introducing new code, not after the maintainer
points it out again. The quoted notes preserve project context; the executable rule is the English text around them.

### A1. Do not reinvent existing UI patterns. A feature lives **inside** the existing dialog/page, it does not redraw it.

- Maintainer note: 「GPG 只是个特性，而不是一个新的软件，你必须保证在一个软件架构内，如果为了这个功能需要重绘的时候，你就得考虑这个页面真的需要重绘吗」
- Every new feature is a feature flag in the existing architecture, not a parallel sub-app. Before writing a new view, sheet,
  or flow: grep the file you're touching for similar rows / controls and reuse the idiom. Don't build a card-style banner
  with rounded backgrounds inside a `Form` whose other rows are bare labels — that's the visual equivalent of forking
  the page.
- "Does this page really need to be redrawn for my feature?" → almost always no. Aim for "one more row / one more
  checkbox / one more `if let` inside the existing view body".
- If you find yourself building a parallel sheet, mirror service, or duplicate menu hierarchy to host a feature, stop and
  fit it into the existing one instead.

### A2. Don't stack DTOs that mirror existing types. If a `mapper` function appears, the second type is likely redundant.

- The pattern to avoid: `BackendType` (enum) → wrap with `OutcomeType` (enum) → mirror to `UIInfo` (struct with own Status
  enum) → write `makeUIInfo(_:)` to translate between them. One concept, three types, plus a mapping function.
- Default to letting the existing type flow all the way to the consumer. Add a wrapping type **only** when the new type
  carries strictly more information *and* removing it would lose a real distinction. A "UI-friendly" rename is not a real
  distinction.
- Two parallel `switch outcome { case .x: ... case .y: ... }` blocks for the same enum across files = combine them into a
  single shared mapping (e.g. an enum with static helpers) and call from both sites.

### A3. Don't add new `NotificationCenter` names for one-publisher / one-subscriber paths.

- If a new feature needs the model to nudge the view exactly once, prefer existing model state changes the view already
  observes (`@Published` properties, `.onChange`, existing notifications). New `Notification.Name` constants are justified
  when there are genuinely multiple potential subscribers or when crossing a process boundary; otherwise they're just an
  obfuscated function call.

### A4. Feature gating is a hard rule, not a soft hint: when a master toggle is off, the feature's UI **does not render**.

- For `AppPreferences.gpgEnabled == false`: every GPG entry point on the main interface must be invisible, not just
  disabled. The Settings pane is the one exception (users need a way to opt in). One narrow data-handling exception is
  documented in the GPG section below.
- The check is `AppPreferences.gpgEnabled`, **not** `GPGBackend.isAvailable()` alone. The backend being installed does not
  mean the user wants GPG features visible. Pair them: `if AppPreferences.gpgEnabled && GPGBackend.isAvailable()`.
- Persisted preferences may still exist with the toggle off; never let them influence the rendered UI of any non-settings
  page while the master toggle is off.

### A5. `.siz` is a tar shell, not a backend. Do not over-architect it.

- `.siz` opens, extracts, and creates entirely on top of the existing archive flow. The container is just
  `tar(archive.<ext> + metadata.json + signature.asc)`. Do not introduce a parallel "SIZ open flow", "SIZ browser",
  or "SIZ extract dialog" — the maintainer has rejected this several times.
- Open `.siz` flow: `unwrap → verify → model.openArchive(innerArchiveURL, displayedAs: originalSIZ)`. That's it.
- Extract `.siz` flow: `unwrap → verify → set ExtractArchiveRequest with sizSignature → existing ExtractArchiveOptionsView
  renders a signature row inside the standard form`. No custom extract destination, no `.unwrapped/` subdirectory, no
  `SIZ_SIGNATURE.txt` sidecar.
- The single exception to A4: opening a `.siz` from Finder must continue to work even with `gpgEnabled == false`. In that
  case skip verification, return `sizSignature: nil`, and let the standard flow take over. No GPG UI surfaces. The file
  is openable because it's a registered file type, not because GPG is enabled.
- Cryptographic design rationale is in `SECURITY.md` under "`.siz` Signed Container Format" — read it before changing the
  wrap / unwrap / verify logic.

### A6. Don't touch `MARKETING_VERSION` or `CURRENT_PROJECT_VERSION` in `SimpleZip.xcodeproj/project.pbxproj`.

- Maintainer note: 「手动改本地版本号毫无价值」.
- CI sets both at build time from `RELEASE_VERSION` / `GITHUB_RUN_NUMBER`. Hand-edits to the project file get overwritten
  and create noisy git diffs.
- When the user asks for "a version bump", change **only**:
  - `CHANGELOG.md` and `CHANGELOG.zh-CN.md` — move unreleased entries under a new `## X.Y.Z` header, leave already-published
    sections untouched.
- Do not edit `Info.plist`'s `CFBundleShortVersionString` or `CFBundleVersion` by hand either; CI patches those during the
  release build.

### A7. Use the system temporary directory; clean up afterward.

- Maintainer note: use a reasonable system temp directory, not an ad hoc project or user-folder scratch path.
- Use `FileManager.default.temporaryDirectory.appendingPathComponent("SimpleZip-...-\(UUID().uuidString)")` for any
  scratch directory. Never write into project directories, the user's Documents folder, or hard-coded `/tmp/foo`.
- Register the temp directory with the existing owner (`TemporaryResourceManager` for archive-open temps, the wrap/unwrap
  helper's `defer` for create-time staging) so it gets cleaned up on app exit or operation completion.

### A8. Do not leave half-wired references. If a method or selector is named, it must compile.

- The pattern to avoid: add a `#selector(gpgSignSelected)` to a menu before `model.gpgSignFile(_:)` exists. The build
  breaks; the next agent inherits a broken tree.
- When introducing a UI hook that calls a model method, write the model method (even as a stub that throws a clearly
  labelled `notImplemented` error or shows a "coming soon" alert) in the same change.
- Or remove the menu item until the backing method lands. **Do not check in code that won't compile.**

### A9. Localization is a hard requirement for every new user-visible string.

- Use `L10n.text("some.key")` for every new label / message / tooltip. Add the key to **both** `en.lproj` and `zh-Hans.lproj`
  (the two primary locales the maintainer maintains by hand). Other locales fall back to `en` automatically.
- Don't hard-code English strings into Swift views even temporarily; that's a regression that ships if forgotten.

### A10. Match scope. A bug fix changes one branch; a refactor changes structure; don't mix them in one diff.

- If the user asks "fix the goUp regression", change the one branch in `goUp`, run the build, report. Don't sneak in
  cleanup of nearby code, even if it's tempting.
- If the user explicitly asks for cleanup, ask whether they want it in the same PR or a separate one before bundling.

### A11. Treat user instructions as cumulative and binding. Re-read prior turns before contradicting them.

- The maintainer issues durable rules (e.g. visibility gating, "no manual version bumps", "use Form rows not cards").
  Once stated, those rules apply to all subsequent work in the same area unless explicitly relaxed.
- If a new request seems to conflict with a prior rule, ask before acting — don't silently override it. Example: if the
  user said "don't redraw the page" earlier in the conversation, don't later introduce a new "signature panel" view
  without first asking whether that exception is wanted.

### A12. Don't blow up the diff with files the user didn't ask you to touch.

- Maintainer note: 「这些代码我根本 review 不了」.
- A diff that touches 12 files for what was supposed to be a one-line behavior change is unreviewable. Before adding
  a new file (new view, new struct in its own file, new helper module), check whether the same change can live as a
  handful of lines inside an existing file.
- If the work genuinely needs new files, surface that scope to the user before writing them, not after.

### A13. NEVER rewrite git history. Commits are append-only. (Hard rule — the maintainer banned this explicitly.)

- Maintainer note: commits are append-only; if a previous change was wrong, restore the intended code with a new forward
  change instead of rewriting or reverting history.
- **Forbidden in all cases:** `git reset --hard`, `git reset` that drops commits, `git revert`, `git commit --amend`,
  `git rebase`, `git push --force`, deleting/moving tags. These destroyed the maintainer's work and broke a release
  before; they are off-limits.
- To "undo" or "change something back", make a **new forward commit**. To restore a file's contents you may
  `git checkout <old-commit> -- <file>` (this edits the working tree, not history) and then commit forward.
- Discarding **your own uncommitted** working-tree changes (`git checkout -- <file>` / `git restore <file>`) is allowed
  because it touches no commit. Do not discard unrelated user changes or pre-existing work.

### A14. Don't reflexively revert/rewrite when given a new requirement or a bug report. Make the SMALLEST change.

- Maintainer note: 「每次提需求，你第一反应就是 revert 重写，各种各样的瞎猜我需求」 and 「你能不能不要动不动就回退」.
- A new requirement is almost never "throw away what exists and rebuild". It is "add the one thing asked, inside what
  already works". Before touching code, identify the **single smallest edit** that satisfies the literal request.
- A bug report is "fix this one behavior", not "redesign the area". Reverting a whole feature to chase a bug the user
  says is unrelated wastes their work — confirm the cause first (A16), then fix the one branch.
- When the maintainer says a UI/version "is good" and asks for one feature, **keep that UI/structure** and add the
  feature as one row / one toggle / one field. Do not redraw it because you think a different design is nicer.

### A15. Do EXACTLY what was asked. Do not guess, expand, or "improve" scope. One ask = one change.

- Maintainer note: 「我只是让你给已添加的选项加复选框，又没让你一次性把全部的都加上，你怎么都喜欢猜我想要什么」 and
  「什么时候让你改其他的了？？？」.
- Touch only what the request names. If asked to "add a switch per added format", add exactly that — do not also
  change the editor, the create dialog, the model shape, or anything adjacent.
- If the requirement is ambiguous and a wrong guess means a big rework, ask **one** precise question before building.
  Do not pick an interpretation and run with it. Repeatedly guessing wrong is worse than asking once.
- After finishing the asked change, **stop**. Report what you did and explicitly say you did not touch anything else.
  Do not volunteer adjacent changes in the same turn.

### A16. For "still broken" / hard bugs, MEASURE before guessing. Don't ship another guess.

- Maintainer note: 「不能再猜了，debug 吧，打 log」.
- If a fix didn't work, the next step is **not** another hypothesis-driven edit. Add temporary instrumentation
  (stderr probes / counters), run the real app, read the data, then fix the proven cause. Remove the probes after.
- A raw crash address or a disassembly listing is not a diagnosis — get the actual call stack / backtrace, or
  reproduce and measure. Don't symbolicate ASLR'd absolute addresses across processes (they mislead).

### A17. The folder-reload path is a `@Published` exclusion zone.

- FSEvents re-lists watched folders (Desktop / Downloads / home) every ~120ms when the system touches them. Any
  `@Published` on `ArchiveBrowserModel` that changes on every reload cycle — even a flag toggling `true → false`
  and back — floods `objectWillChange`, and `@FocusedObject` rebuilds the entire menu-bar `.commands` tree each
  time, killing open menus. This bug was fixed once and **reintroduced the same day** by a new published
  in-flight flag (`e012098` reverted it to a plain var).
- Before adding state to `ArchiveBrowserModel`, ask: does `loadFolder → applyLoadedFolder` mutate it every cycle?
  If yes, plain var (render-time *reads* are fine — rendering is driven by `mode` / `fileItems`). If it genuinely
  must publish, compare before assigning — `@Published` does not dedupe equal values.

### A18. Never block the main thread waiting on async work — the app target is MainActor-by-default.

- `ArchiveService` entry points (and most unannotated declarations) are MainActor-isolated under the app target's
  default isolation. Parking the main thread on a `DispatchSemaphore` while a detached task awaits them is a
  guaranteed deadlock (the CLI's first smoke run hung exactly this way).
- Patterns that work: keep the calling flow `async` on the actor (the CLI uses `Task { @MainActor in … }` +
  `RunLoop.main.run()`), or mark genuinely pure helpers `nonisolated` so any context can call them. Fix isolation
  warnings by annotating correctly — never paper over them with a blocking wait.
- **Not `dispatchMain()`**: it parks the real main thread and lets a worker with main-queue *semantics* run
  MainActor jobs — the actor is satisfied, but AppKit checks `pthread_main_np()`, so instantiating any
  NSWindow/NSAlert from that flow throws `NSInternalInconsistencyException` (the CLI password dialog crashed
  exactly this way; measured). `RunLoop.main.run()` keeps the true main thread serving the queue.

### A19. `Bundle.main` lies when the binary is invoked through a symlink (CLI companion).

- Measured: launched via `/usr/local/bin/simplezip → …/Contents/MacOS/SimpleZip`, `Bundle.main.bundlePath` is the
  **symlink's directory**, `bundleIdentifier` is nil, every resource lookup fails, and `UserDefaults.standard`
  points at the wrong domain.
- Code that may run in the CLI process must locate the real bundle from `_NSGetExecutablePath` +
  `resolvingSymlinksInPath()`, feed the bundled 7zz through the existing `SIMPLEZIP_7ZZ_PATH` hook, and open
  preferences via `UserDefaults(suiteName: <app bundle id>)`. L10n cannot resolve there — CLI output is
  deliberately English-only.

### A20. Scripted bulk edits to Swift sources must anchor on long unique snippets — and build before commit.

- A python/sed pass matching a generic closer like `"}\n    }"` hits the wrong brace and can silently duplicate an
  entire struct (happened to `FilePermissionsEditor`; recovered only because the tree was clean and
  `git restore` could redo it). Anchor on full multi-line snippets, assert match counts, and never mix a bulk
  edit with other uncommitted work.
- After any scripted edit, run the real build before committing — compiling is the only proof the script did what
  you intended.

### A21. New `AppPreferences` keys must be registered in the backup surface — twice.

- Every new settings key needs entries in **both** `exportableUserDefaultsKeys` and `exportableSnapshot()`;
  `PreferencesPayloadCodecTests` fails on the snapshot half, but only if you remembered the first half. Missing
  either silently drops the setting from settings backup/restore.

### A22. CHANGELOG formatting: per-version sections are grouped by change type, then split user- vs developer-facing.

Both `CHANGELOG.md` and `CHANGELOG.zh-CN.md` are edited together (bilingual mirror), one entry per item, written
for readers (what changed + why). The two files must stay structurally identical — same headers, same bullet order,
same grouping — only the prose language differs.

**Structure inside a `## X.Y.Z` version section (maintainer-mandated, 0.4.4+):**

- Group every bullet under a `###` type header, in this order — use exactly these (English file shown; the zh file
  uses the parenthesized Chinese label):
  - `### feat` (新功能) — brand-new capabilities
  - `### UX` (交互与界面) — interaction / layout changes to things that already existed
  - `### bugfix` (修复) — fixes for broken behavior
  - `### improvements` (改进) — making existing things better (perf, polish) without being a fix
  - `### misc` (杂项) — small leftovers that don't fit above
- Within each type header, split the bullets under a bold sub-label — **User-facing** (面向用户) first, then
  **Developer-facing** (面向开发者). User-facing = what a regular archive-manager user sees; developer-facing =
  publishing toolchain (Release Assistant suite), CLI, Shortcuts/automation, machine-readable outputs, DevTools and
  internal refactors. Omit a sub-label (and its blank line) if that half is empty; omit a whole `###` group if it
  has no bullets.
- **No blank lines between bullets** inside a sub-label group (a stray blank line is a formatting bug the maintainer
  has hand-fixed before). Blank lines DO go around `###` headers and `**…**` sub-labels for readability.

**While a version is still unreleased, keep merging — don't append blow-by-blow.** New work folds into the existing
final-state bullet for that feature instead of stacking a fresh bullet per commit. The changelog describes what the
release delivers vs the previous version, not the iteration history (e.g. a feature shipped then tweaked is ONE
bullet describing the end state).

**The in-app renderer is `inline-only` — mind block markup.** Settings → Software Update renders the section through
`AttributedString(markdown:, .inlineOnlyPreservingWhitespace)`, which processes inline syntax (bold / code / links)
but NOT block elements. `### type` headers are normalized to bold lines by `ChangelogFeed.Release.attributedBody`
(UpdatesPane.swift) so they don't leak literal hashes; keep that normalization working if you touch either side.
`- ` bullet dashes stay literal in-app (expected). Never rely on tables, blockquotes or nested lists rendering
in-app. `~` and `_` are escaped outside backtick code spans to avoid cross-line strikethrough/italic — don't defeat it.

### A23. Do not stop while unblocked work remains. "Keep going until it's done" is a standing hard rule.

- Maintainer note (added to memory many times, then to this file): 「白皮书没做完前不要停」, and repeatedly
  「你怎么又停了？？？」. This is the single most repeated complaint — treat it as a top-priority rule, not a nicety.
- The exact anti-pattern to never do: finish a coherent unit, then end the turn with a recap + "should I continue?" /
  "要不要我接着做" / "要不要你拍个板". The maintainer reads that as stopping. Asking permission to keep doing the
  work that was already requested is the failure.
- None of these are stopping points, and none mean the task is done: a green/verified milestone; a long turn or large
  context; "I already delivered a lot"; a tidy checkpoint; the next chunk being big or interdependent. The task is done
  only when the whitepaper (#80) / the explicitly-requested scope is fully implemented **and wired into the App**
  (acceptance: "只新增 Core 类型但 App view 没调用 = 不合格"), not when a convenient pause appears.
- Keep working commit-by-commit. Each commit must still compile + verify (A8 / A20 — finish an atomic change before
  committing, never check in a broken tree). But finishing one commit means **starting the next**, not handing back.
  If a change is a large atomic ripple, complete the whole ripple and build before committing — do not stop midway.
- The ONLY legitimate reasons to hand back mid-task: (a) a genuine decision only the user can make that cannot be
  resolved from the request, the code, sensible defaults, or the whitepaper itself — and even then prefer the sensible
  default and keep going; (b) a hard external blocker (missing tool / credentials / unavailable backend). Token or
  context budget is the harness's concern, not a reason to self-terminate with a wrap-up.
- Progress reporting is fine **inline, as one line before the next tool call**. It is NOT fine as a turn-ending
  "here's everything I did — want me to keep going?". Report, then immediately do the next thing.
- Applies with full force to #80 and to anything the maintainer frames as "不能停 / 一次性做完 / 做完才能停".

### A24. Comments and commit/PR messages describe the code and the change only — never the conversation that produced them. **Binds every agent, including background / spawned ones.**

- A comment states what the code does, plus a terse technical reason for a non-obvious design choice. A commit / PR
  message states the change technically: what changed and why. Stop there.
- Keep out of every committed artifact (comment, commit message, CHANGELOG, any tracked file): the chat back-and-forth,
  the debugging or investigation process, anything about the user, and which model or how many agents did the work. None
  of that describes the code — it is internal communication and stays in the session, not the repo.
- Technical vocabulary is fine and expected (App Intents, UserDefaults, XPC, symlink, an OS error code, a CVE) — it
  describes the code, not the conversation. The ban is on internal-communication narrative, not on technical terms.
  In-app user-facing strings are stricter still — A9 / the L10n rules forbid internals there entirely.
- A comment that justifies a design choice gives the engineering reason, not the story of how it was found.
- Spawning an agent that may write code, comments, or commits → state this constraint in its prompt; do not assume it
  inherited it.
- Before committing, reread the diff and the message and cut anything that narrates the process or the conversation
  rather than the change.

## Testing Rules

- Do not modify unit tests by default.
- If tests fail, diagnose and fix production code first.
- If a test appears incorrect or outdated, explain why, explain the intended correct behavior, and request user approval
  before editing the test.
- Do not weaken assertions or remove coverage just to make verification pass.
- Prefer tests around pure core behavior, command argument generation, path normalization, safety prompts, conflict
  decisions, parsing, and temporary-resource behavior.

## Failure Handling

If lint, tests, or builds fail:

1. Report the failing command.
2. Explain the root cause from the actual output, not guesswork.
3. Identify the production code responsible when applicable.
4. Fix production code first.

If the failure cannot be resolved without changing expected behavior, state:

```text
Test behavior may be outdated, confirmation required before modifying tests
```

## Verification Integrity

- Never fabricate, summarize imaginary, or simulate command results.
- If a command was not executed, state `verification not executed`.
- If a command result is incomplete or ambiguous, state `verification uncertain`.
- If sandboxing, missing tools, code signing, unavailable backends, or environment issues block verification, explain the
  blocker and what command should be run once unblocked.

## Non-Business Changes

For changes that only touch documentation or agent instructions:

- skip lint and test/build verification;
- do not run expensive builds unless the user explicitly asks;
- state in the final response that verification was intentionally skipped under the documentation-only rule.
