**English** | [中文](./URL-SCHEME.zh-CN.md)

# SimpleZip URL Scheme

SimpleZip registers the `simplezip://` URL scheme so other apps, scripts, and automations on the same Mac can ask it to
perform archive actions. Every action is **confirmed in the app first** by default, but you can set up an automation key
in Settings to skip confirmation for your own scripts.

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

All six verbs take the host position of the URL (`simplezip://<verb>`) and read their operands from query parameters.
Parameter names are exact and case-sensitive.

| Verb | URL shape | Parameters |
| --- | --- | --- |
| Check | `simplezip://check?path=…` | `path` |
| Compare | `simplezip://compare?left=…&right=…` | `left`, `right` |
| Open | `simplezip://open?path=…` | `path` |
| Extract | `simplezip://extract?path=…` | `path` |
| Hash | `simplezip://hash?path=…` | `path` |
| Create | `simplezip://create?path=…&format=zip\|7z\|tgz` | `path`, `format` |

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

### Extract — `simplezip://extract?path=…`

Extracts the archive at `path`. The destination is picked in the dialog or follows your saved defaults.

```bash
open "simplezip://extract?path=/Users/me/Archives/archive.zip"
```

### Hash — `simplezip://hash?path=…`

Computes the SHA-256 checksum of the file at `path`.

```bash
open "simplezip://hash?path=/Users/me/Archives/release.tar.gz"
```

### Create — `simplezip://create?path=…&format=…`

Packs the file or folder at `path` into an archive of the given format. `format` accepts `zip`, `7z`, and `tgz`.

```bash
open "simplezip://create?path=/Users/me/Documents/project&format=zip"
```

## Path requirements

- **Absolute paths only.** Each path parameter must begin with `/`. Relative paths, `~`, and non-absolute values are
  rejected and the URL is ignored.
- **Percent-encode where needed.** Spaces and other reserved characters in a path must be URL-encoded (a space becomes
  `%20`).

When a value does not meet these requirements, the URL does nothing; SimpleZip does not fall back to a guess or a default
path.

## Automation key

`simplezip://` is a global scheme — any local process can construct one of these URLs — so SimpleZip prompts for
confirmation on every URL from another app by default. If you are calling SimpleZip from your own scripts or local
automation tools, you can configure an **automation key** to bypass the prompt.

### Getting your key

Open SimpleZip → Settings → Automation. In the "URL Scheme" section, find the "Trusted key" row. Click the "Copy" button
next to it to copy the key to your clipboard.

The key is a per-machine unique UUID. It is excluded from the settings backup — moving to a new Mac generates a fresh key
and you will need to update your scripts.

### Using the key in URLs

Add `key=your-key` to the query parameters of any `simplezip://` URL:

```bash
# Without key → shows confirmation dialog
open "simplezip://check?path=/Users/me/test.7z"

# With correct key → runs immediately, no prompt
open "simplezip://check?path=/Users/me/test.7z&key=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
```

URLs carrying the correct key run **immediately, with no confirmation dialog**. This takes precedence over the
"Require confirmation" toggle — correct-key URLs are always executed directly.

### "Require confirmation from other sources" toggle

This toggle (Settings → Automation → URL Scheme) controls the behavior of URLs that do **not** carry the key:
- **On** (default): URLs without the key show a confirmation dialog.
- **Off**: All URLs run without confirmation, key or not.

Turning this toggle off means any process that can run `open` on your Mac can direct SimpleZip to perform archive
operations without restriction. Only do this if you fully trust your local environment and understand the risk.

> The SimpleZip actions in the Shortcuts app use the App Intents channel and do **not** use this key.

> A separate internal host, `simplezip://finder-action`, backs the Finder right-click services and is **not** part of
> this public scheme. It has its own stricter validation (the payload must be a regular, non-symlink JSON file directly
> inside the user's temporary directory) and is not meant to be constructed by hand.

## Where results appear

URL-scheme actions feed into the same task pipeline as the rest of the app, tagged with a URL-scheme source. Check and
compare results, along with any errors, appear in the **Activity Center**. The Automation settings pane also shows when
the URL scheme was last used and aggregates per-source statistics.

## See also

- [`CLI.md`](./CLI.md) — the `simplezip` command-line companion.
- [`SHORTCUTS.md`](./SHORTCUTS.md) — the macOS Shortcuts and App Intents automation surface.
- [`../SECURITY.md`](../SECURITY.md) — the project's security model and threat assumptions.
