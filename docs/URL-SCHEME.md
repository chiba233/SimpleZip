**English** | [中文](./URL-SCHEME.zh-CN.md)

# SimpleZip URL Scheme

SimpleZip registers the `simplezip://` URL scheme so other apps, scripts, and automations on the same Mac can ask it to
perform a small set of archive actions. Every action is **confirmed in the app first**: when a `simplezip://` URL
arrives, SimpleZip shows a dialog that names the action and the full file paths, and nothing runs until you click **OK**.

> This document describes the public URL verbs. For the equivalent terminal commands see [`CLI.md`](./CLI.md); for the
> macOS Shortcuts / App Intents surface see [`SHORTCUTS.md`](./SHORTCUTS.md).

## Registration

The scheme is declared in the app bundle's `Info.plist` under `CFBundleURLTypes`:

```xml
<key>CFBundleURLTypes</key>
<array>
    <dict>
        <key>CFBundleURLName</key>
        <string>SimpleZip Finder Actions</string>
        <key>CFBundleURLSchemes</key>
        <array>
            <string>simplezip</string>
        </array>
    </dict>
</array>
```

Once SimpleZip has been launched at least once, macOS routes `simplezip://` URLs to it. You can trigger one from the
command line for testing:

```bash
open "simplezip://check?path=/Users/me/Archives/build.zip"
```

## Actions

All three verbs take the host position of the URL (`simplezip://<verb>`) and read their operands from query parameters.
Parameter names are exact and case-sensitive; the parser confirms them rather than guessing.

| Verb | URL shape | Parameters |
| --- | --- | --- |
| Check | `simplezip://check?path=…` | `path` |
| Compare | `simplezip://compare?left=…&right=…` | `left`, `right` |
| Open | `simplezip://open?path=…` | `path` |

The scheme name (`simplezip`) and the verb are matched case-insensitively. `simplezip://test?path=…` is accepted as an
alias for `simplezip://check?path=…`.

### Check — `simplezip://check?path=…`

Tests the integrity of the archive at `path`. After you confirm, the archive is enqueued for testing and the result is
reported in the Activity Center.

```bash
open "simplezip://check?path=/Users/me/Archives/release.7z"
```

### Compare — `simplezip://compare?left=…&right=…`

Compares two archives (or folders) given by `left` and `right`. Both parameters are required; if either is missing the
URL is ignored. The comparison result lands in the Activity Center.

```bash
open "simplezip://compare?left=/Users/me/Archives/old.zip&right=/Users/me/Archives/new.zip"
```

### Open — `simplezip://open?path=…`

Opens the file or archive at `path` in SimpleZip, the same as opening it from Finder.

```bash
open "simplezip://open?path=/Users/me/Archives/photos.zip"
```

## Path requirements

- **Absolute paths only.** Each path parameter must begin with `/`. Relative paths, `~`, and non-absolute values are
  rejected and the URL is ignored — SimpleZip will not run the action.
- **Percent-encode where needed.** Spaces and other reserved characters in a path must be URL-encoded (for example a
  space becomes `%20`). The values are read back from the URL's query items as written.

When a value does not meet these requirements, the URL simply does nothing; SimpleZip does not fall back to a guess or a
default path.

## Mandatory confirmation

`simplezip://` is a global scheme. **Any local process — another app, a script, or even a web page handed to `open` — can
construct one of these URLs.** A scheme registration is not, by itself, an authorization boundary, so SimpleZip never
acts on a URL silently.

Before running any verb, SimpleZip:

1. Brings itself to the foreground.
2. Presents a confirmation dialog that **names the action and shows the full file path(s)** it is about to use.
3. Runs the action **only if you click OK**. Clicking Cancel discards the request and nothing happens.

This confirmation is intentional and is **not configurable** — the URL scheme is always confirm-first. The Automation
settings pane lists the scheme and the example URLs for reference, but it does not offer a way to disable the prompt.

The paths are validated (absolute-path check above) before the dialog is even shown, and the dialog is your final review
of exactly what will run.

> A separate internal host, `simplezip://finder-action`, backs the Finder right-click services and is **not** part of
> this public scheme. It has its own stricter validation (the payload must be a regular, non-symlink JSON file directly
> inside the user's temporary directory) and is not meant to be constructed by hand.

## Where results appear

URL-scheme actions feed into the same task pipeline as the rest of the app, tagged with a URL-scheme source. Check and
compare results, along with any errors, appear in the **Activity Center**. The Automation settings pane also shows when
the URL scheme was last used and aggregates per-source statistics.

## See also

- [`CLI.md`](./CLI.md) — the `simplezip` command-line companion (`open` / `check` / `compare` / `create` / `verify`).
- [`SHORTCUTS.md`](./SHORTCUTS.md) — the macOS Shortcuts and App Intents automation surface.
- [`../SECURITY.md`](../SECURITY.md) — the project's security model and threat assumptions.
