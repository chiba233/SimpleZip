**English** | [中文](./AI-AGENT.zh-CN.md)

# SimpleZip On-Device AI Helpers (Agent & XPC Service)

All on-device model **inference** in SimpleZip runs in helper processes *outside* the main app binary. The app builds
Codable input DTOs and calls `AIAgentClient`, which serializes one typed XPC call; the process on the other end imports
`FoundationModels`, builds the prompt, runs the model, and parses the result. The main app binary never creates a
`LanguageModelSession` — only a read-only "is the model available?" check still touches `FoundationModels`.

This document describes those helper processes: the two delivery channels, the `SimpleZipAIAgent` command-line flags,
the XPC contract, the config-sync payload, and the launchd / `SMAppService` registration.

> For the high-level rationale see [`ARCHITECTURE.md` → On-Device AI](./ARCHITECTURE.md). For the **end-user** terminal
> tool (`simplezip`), which is a completely different thing, see [`CLI.md`](./CLI.md). These helpers are internal and not
> meant to be run by users.

## Two channels, one engine

Both channels run the same `AIPassEngine` (in `SimpleZipAgentSupport/AIAgentService.swift`, compiled only into the helper
targets) behind the **same global serial gate**, so the on-device model is never entered by two overlapping `respond()`
calls. Normally the app is open → the XPC Service is alive; the app is closed → the LaunchAgent does background work; the
two processes do not run at the same time.

| | **XPC Service** (`SimpleZipAIXPCService.xpc`) | **Agent / LaunchAgent** (`SimpleZipAIAgent`) |
|---|---|---|
| Role | Foreground, on-demand inference | Background index when the app is closed; on-demand Mach probes |
| Lives in | `SimpleZip.app/Contents/XPCServices/` | `SimpleZip.app/Contents/MacOS/` (helper); plists in `Contents/Library/LaunchAgents/` |
| Launched by | `NSXPCConnection(serviceName:)` — launchd starts it when the app connects | `SMAppService` + launchd (`StartInterval`, or on Mach connect) |
| Lifecycle | Bound to the app (`XPCService.ServiceType = Application`); dies with the app | Survives app exit; launchd wakes it on a schedule |
| Login Items / "allow in background" | **No** — not a Login Item, not gated | **Yes** — appears in Login Items, gated by "allow in background" |
| Entry point | `AIXPCServiceMain.swift` (`NSXPCListener.service()`) | `AIAgentMain.swift` |

The `SimpleZipAIAgent` binary backs **two** launchd jobs (see [registration](#launchd--smappservice-registration)): a
resident on-demand Mach listener (default, no arguments) and a periodic background-index job (`--background-index`).

## `SimpleZipAIAgent` command-line flags

These flags are for development, diagnostics, and launchd — **not** an end-user CLI. The executable lives at
`SimpleZip.app/Contents/MacOS/SimpleZipAIAgent` (the debug build is `SimpleZip-dev.app`). Output goes to stderr (visible
in Console) and stdout.

| Flag | What it does |
|---|---|
| *(no arguments)* | Start a resident `NSXPCListener` bound to the Mach service name and wait for app / launchd connections. This is the LaunchAgent's default mode. |
| `--background-index` | Run **one** background-index pass and exit. This is what launchd runs on a schedule (and how you verify the data path by hand). Reads the app-synced config + scope allow-list, scans metadata, bakes summaries via the on-device model, writes the derived index, records run telemetry, and exits. If gating fails (opt-in off, etc.) it is a cheap no-op exit. |
| `--background-index --force` | Same, but bypass the interval self-throttle and the app/agent foreground lock (for testing). **Gating and red lines still apply** — the AI master switch and privacy rules are not bypassed. |
| `--probe` | Run one minimal on-device model probe in this (standalone) process and exit. Answers the foundational question "can the on-device model run outside the app?" without SMAppService/launchd/XPC. |
| `--query <text>` | Run a **real** structured generation: turn a natural-language request into an archive search keyword, print it, and exit. Verifies real (non-hardcoded) generation without XPC/GUI. |
| `--test-backend <archive>` | Run one `ArchiveService.list` (really spawns `7zz`) inside the agent process and report the entry count. Verifies the backend works in the helper process (`Bundle.main` resolves to the app bundle, so `Resources/Tools/7zz` is found). |
| `--config-selftest` | Build a config, encode → decode → compare, print the round-trip result, and exit. Pure Foundation; no model or XPC. |

Examples:

```sh
APP="/Applications/SimpleZip.app/Contents/MacOS/SimpleZipAIAgent"
"$APP" --background-index --force          # force one background-index pass now
"$APP" --probe                             # is the on-device model reachable here?
"$APP" --query "where did I zip the budget spreadsheet"
"$APP" --test-backend ~/Downloads/test.zip
```

## XPC interface (`SimpleZipAIAgentXPC`)

An `@objc` protocol (required by `NSXPCConnection`), shared by both channels. Every method replies on an arbitrary queue
via a reply block.

| Method | Returns | Notes |
|---|---|---|
| `ping` | `Bool` | Lightweight liveness check — does **not** run the model; returns instantly. Used by the Health pane so status checks never hang on a slow generation. |
| `modelAvailability` | `(Bool, reasonCode)` | On-device model availability. `reasonCode ∈ {"", "deviceNotEligible", "notEnabled", "modelNotReady", "osTooOld"}`; the app maps the code to a localized string. Read-only, instant. |
| `probeModel` | `String` | Try one minimal generation and return a human-readable result (success + sample / reason unavailable). |
| `extractArchiveKeyword(fromRequest:)` | `String` | Real structured generation: natural-language request → archive search keyword (or a human-readable error). |
| `syncConfiguration(_:)` | `Int` | App → agent config sync (JSON `Data`). The agent decodes, stores, and gates on it; replies with the schemaVersion it supports (`-1` on decode failure, so the app can negotiate / downgrade). |
| `generate(kind:inputJSON:languageName:)` | `(Data, Bool)` | Generic AI-pass generation. `kind = AIPassKind.rawValue`; `inputJSON` is the pass's Codable input DTO; `languageName` is the UI language (the engine has no app locale). `ok == true` → `Data` is the output DTO; `ok == false` → `Data` is a UTF-8 human-readable error. **Red line: master/sub switch off → `ok == false` ("AI disabled").** |
| `passStats` | `Data` | Per-pass-kind call stats since process start (`[AIPassStatEntry]`: total / success / failure / last time + outcome) for DevTools monitoring. No model, instant. |

The app-side client is `AIAgentClient` (`SimpleZip/Features/AI/AIAgentClient.swift`): `runForegroundProbe` /
`runForegroundQuery` / `generatePass(kind:input:as:)` / `pingForegroundBackend` / `fetchModelAvailability` use the XPC
Service channel; `runBackgroundProbe` uses the LaunchAgent (Mach) channel. First connections retry once to absorb a cold
launchd start race.

## Configuration sync (`AIAgentConfiguration`)

The app encodes its current AI settings into a JSON `Data` payload (carrying `schemaVersion`, currently `4`) and pushes
it to the agent; the agent gates generation on it.

| Field | Meaning |
|---|---|
| `aiAssistantEnabled` | **AI master switch. Red line: `false` = the entire agent AI capability is disabled** (no generation, no indexing, no preread) — the foreground is not exempt. |
| `aiSuggestionEnabled` | AI suggestions sub-switch. |
| `indexingEnabled` / `contentPrereadEnabled` | Background index / content-preread switches. |
| `activityLevel` | Background activity tier (`AIBackgroundActivityLevel.rawValue`). |
| `silentBackgroundIndexEnabled` | Whether the agent keeps indexing **after the app closes** (a separate opt-in from "index while the app is open"). The interval/timeout below only matter when this is true. |
| `backgroundIndexIntervalHours` | Background-index trigger interval; launchd wakes the agent on it. |
| `maxBackgroundRunSeconds` | Max duration of one background run; over it, stop and continue next time. Power gating reuses `AIBackgroundSchedulingRules`. |
| `languageName` | UI language name (e.g. `"Simplified Chinese"`) so background baking produces summaries in the right language. Missing in old payloads → decodes back to `"English"`. |

**Persistence.** The app writes the payload atomically to
`Application Support/<app-bundle-id>/AIAgentConfig.json` (dev/prod isolated). Any agent process started by launchd reads
it, so even a background agent woken while the app is closed has the current config — crucially the red-line master
switch.

**Run telemetry.** Every time the agent is woken for `--background-index` it records one entry (run count / last wake /
last outcome) in the app's preferences domain, so the app and DevTools can confirm the background agent really was woken,
how often, and with what result — a "last successful index" timestamp alone can't show whether launchd is firing.

## launchd / `SMAppService` registration

The agent is registered with `SMAppService.agent(plistName:)` (macOS 13+); the plists are embedded in
`SimpleZip.app/Contents/Library/LaunchAgents/`. There are two:

- **`<machService>.plist`** — the resident on-demand Mach listener. Declares only `MachServices` (named after the agent);
  launchd starts it when something connects. Used for DevTools probes and the app → agent Mach channel.
- **`<machService>.index.plist`** — the periodic background-index job. `ProgramArguments` run the helper with
  `--background-index` (run one pass, then exit — not a resident listener), with `StartInterval 21600` (a 6-hour base
  cadence; longer configured intervals are honored by the agent's own self-throttle), `RunAtLoad`,
  `ProcessType Background`, and `LowPriorityIO` so the OS manages power.

**Namespace isolation.** Debug uses the `.dev.*` namespace and Release uses the plain `.*` namespace, so a self-signed
dev build and the Developer ID release can coexist without colliding in SMAppService / launchd / BTM (BTM attributes a
job to an app by the bundle-id prefix of its `Label`). CI (`build_dmg.sh`) strips the `.dev` plists from the release
artifact.

| Constant | Debug | Release |
|---|---|---|
| Mach service (LaunchAgent) | `yumeka.SimpleZip-in-mac.dev.aiagent` | `yumeka.SimpleZip-in-mac.aiagent` |
| XPC service name (= XPC Service `CFBundleIdentifier`) | `yumeka.SimpleZip-in-mac.dev.aixpc` | `yumeka.SimpleZip-in-mac.aixpc` |
| Background-index plist | `<machService>.index.plist` | `<machService>.index.plist` |

## Privacy & gating (red lines)

- **Master switch off → all agent AI capability is disabled** (no generation, indexing, or preread); the foreground is
  not exempt. Enforced both by the pushed config and re-checked in the engine.
- **Silent background indexing is a separate opt-in** and is additionally power-gated (`AIBackgroundSchedulingRules`) and
  interval-throttled; launchd's base cadence is 6 hours, the effective cadence follows the config.
- **Never fed to the model:** passwords, encrypted archive entry names, GPG ciphertext, or decrypted plaintext. Inputs
  pass through `AISensitiveRedactor` first.
- Background indexing itself is a pure metadata scan; only summary baking calls the on-device model — and only ever in a
  helper process. The main binary imports `FoundationModels` solely for the read-only availability check.

## Related

- [`ARCHITECTURE.md`](./ARCHITECTURE.md) — On-Device AI (separate process): the design rationale and pass contract.
- [`CLI.md`](./CLI.md) — the end-user `simplezip` terminal tool (unrelated to these helper flags).
