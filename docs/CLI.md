**English** | [中文](./CLI.zh-CN.md)

# `simplezip` — Command-Line Companion

`simplezip` is a command-line companion for the SimpleZip macOS app. It is **not** a
separate tool: it is the same app binary, invoked under a different name through a
symlink on your `PATH`. Because of that, every command drives the **same bundled
engines** the app uses — the bundled 7-Zip engine, the optional RAR and GPG backends,
and the same archive, checksum, and diff logic — and produces the same results with the
same safety checks.

When you launch the binary as `simplezip` (or pass a leading `--cli`), the process runs
in CLI mode: it does **not** open the main window. It runs the requested command against
the real backends, prints its result, records the finished command in the app's
**Activity Center**, and exits with a status code suitable for scripts and CI.

## Installing and removing the command

Install and remove the command from the app: **Settings → Automation → Command-Line
Tool**.

- **Install** creates a symlink at `/usr/local/bin/simplezip` pointing at the app's
  binary. If `/usr/local/bin` is not writable (the default on Apple Silicon, where it is
  owned by `root`), the app shows the standard macOS **administrator authorization
  dialog** to create the link. The password is handled by the system Security framework
  and never passes through the app.
- If that authorization is cancelled or fails, the app falls back to showing a
  ready-to-copy `sudo` command so you can create the link yourself:

  ```
  sudo mkdir -p /usr/local/bin && sudo ln -sf '/path/to/SimpleZip.app/Contents/MacOS/SimpleZip' /usr/local/bin/simplezip
  ```

- **Uninstall** removes the symlink (again falling back to an administrator dialog, then
  to `sudo rm /usr/local/bin/simplezip` if needed).

The Settings pane shows the current status — installed, missing, or occupied by a link
that points elsewhere (a stale copy or a same-named third-party tool). If the app is
running from a Gatekeeper-translocated location (an un-quarantined DMG launched in
place), installation is disabled, because the link would point at a one-time temporary
mount path; move the app into **Applications** first.

## Usage

The top-level usage string is:

```
simplezip — SimpleZip command-line companion

USAGE:
  simplezip open <file>...                   Open files or archives in the SimpleZip app
  simplezip check <archive>...               Test archive integrity (exit 1 on any failure)
  simplezip compare <left> <right>           Compare two archives (exit 1 when different)
  simplezip create <output> <input>... [options]
                                             Create an archive; format from the output extension
  simplezip verify <checksum-file>...        Verify SHA256SUMS / checksums.txt / .sha256 / .md5 / .sfv
  simplezip doctor                           Check the CLI environment (app, backends, symlink)
  simplezip version                          Print version
  simplezip help [command]                   Show this help, or detailed help for one command

GLOBAL OPTIONS:
  --json        Print one JSON result object per command on stdout
  --quiet, -q   Only errors and the exit code
  --verbose     Stream the backend's raw output

NOTES:
  Finished commands are also recorded in the app's Activity Center.
  Passwords are never accepted on the command line — see `simplezip help create`.
  Exit codes: 0 success · 1 failures or differences found · 2 usage or environment error
```

Run `simplezip help` (or `simplezip` with no arguments) for this text, and
`simplezip help <command>` for the detailed help of a single command.

## Global options

These flags may appear anywhere on the command line; they are stripped before the
subcommand is parsed.

| Flag | Effect |
| --- | --- |
| `--json` | Print one JSON result object per command on stdout. |
| `--quiet`, `-q` | Print only errors and the exit code. |
| `--verbose` | Stream the backend's raw output. |

## Exit codes

The convention is shared between every command and the usage text:

| Code | Meaning |
| --- | --- |
| `0` | Success. |
| `1` | Failures or differences found. |
| `2` | Usage or environment error. |

## Commands

### `open`

```
simplezip open <file>...
```

Opens files or archives in the SimpleZip app (equivalent to double-clicking them).

### `check`

```
simplezip check <archive>... [--json] [--quiet] [--verbose]
```

Tests archive integrity with the bundled 7-Zip engine. Multiple archives are tested one
by one and a summary line is printed at the end. Encrypted archives prompt with a small
dialog — passwords never touch the command line. Exit `1` if any archive fails.

With `--json`, the output object is:

```json
{
  "command": "check",
  "results": [ { "path": "/abs/archive.zip", "ok": true } ],
  "passed": 1,
  "failed": 0
}
```

Each entry in `results` carries `path`, `ok`, and — on failure — an `error` string.

### `compare`

```
simplezip compare <left> <right> [--json] [--quiet]
```

Compares the entry lists of two archives (path, size, CRC, modified, encryption). Exit
`1` when they differ, `0` when identical.

The plain-text output lists differences as `+ name` (added), `- name` (removed), and
`~ path (fields…)` (changed), followed by a summary line. With `--json`, the output
object is:

```json
{
  "command": "compare",
  "identical": true,
  "added": 0,
  "removed": 0,
  "changed": 0,
  "unchanged": 12
}
```

### `create`

```
simplezip create <output> <input>... [options]
```

Creates an archive. The format comes from the output extension (`zip`, `7z`, `tar`,
`tar.gz`, …). Your saved per-format defaults (**Settings → Compression**) apply
automatically; the flags below override them. **Never overwrites an existing output
file.** All inputs must live in the same directory.

```
OPTIONS:
  --template, -t <name>   Apply a built-in task template (github-release,
                          windows-friendly, max-7z, encrypted-delivery,
                          source-code, backup)
  --level, -l <0-9>       Compression level
  --exclude-junk          Skip .DS_Store, AppleDouble, Thumbs.db, desktop.ini
  --reproducible          Deterministic output (zip/7z): same input,
                          byte-identical archive
  --encrypt               Encrypt the archive. The password is read from the
                          SIMPLEZIP_PASSWORD environment variable, or prompted
                          interactively on the terminal (never echoed).
                          It is NEVER accepted as a command-line argument.
```

Notes on individual options:

- `--template` selects a built-in task template; the template carries its own format, so
  the output name's extension must match it.
- `--reproducible` only applies to `zip` and `7z` outputs.
- `--encrypt` requires a format that supports encryption. The password comes from the
  `SIMPLEZIP_PASSWORD` environment variable, or from an interactive (non-echoed) terminal
  prompt — never from `argv`.

With `--json`, the output object is:

```json
{
  "command": "create",
  "ok": true,
  "output": "/abs/output.zip",
  "sizeBytes": 12345
}
```

`sizeBytes` is omitted if the output size cannot be read.

### `verify`

```
simplezip verify <checksum-file>... [--json] [--quiet]
```

Verifies the files listed in checksum files (GNU `sha256sum` format, BSD tag format, bare
digests, `.sfv`). Paths are resolved relative to each checksum file; unsafe entries
(absolute paths, `..`) are rejected. Exit `1` if anything fails; a summary line is printed
per file and for the whole run.

With `--json`, the output object is:

```json
{
  "command": "verify",
  "files": [ { "file": "SHA256SUMS", "passed": 3, "failed": 0 } ],
  "passed": 3,
  "failed": 0,
  "ok": true
}
```

### `doctor`

```
simplezip doctor [--json]
```

Checks the CLI environment: the `SimpleZip.app` this command belongs to, the bundled
7-Zip engine, the optional RAR and GPG backends, and whether the
`/usr/local/bin/simplezip` symlink points at this app. It is read-only.

If the bundled 7-Zip engine cannot be located, `doctor` exits `2`; the RAR and GPG
backends are optional and are reported as-is. With `--json`, the output object is:

```json
{
  "command": "doctor",
  "app": "/Applications/SimpleZip.app",
  "version": "X.Y.Z (build)",
  "sevenZip": { "path": "/…/Contents/Resources/7zz", "version": "…" },
  "rar": { "version": "…" },
  "gpg": { "available": true },
  "symlink": { "path": "/usr/local/bin/simplezip", "status": "ok → /…" }
}
```

### `version`

```
simplezip version
```

Prints the app version this CLI belongs to. With `--json`:

```json
{
  "command": "version",
  "version": "X.Y.Z (build)"
}
```

### `help`

```
simplezip help [command]
```

Shows the top-level help, or detailed help for one command.

## Passwords

Passwords are **never** accepted as command-line arguments.

- `check` (and the other read commands) prompt for a password through a small dialog when
  they hit an encrypted archive; the password is fed straight to the engine and never
  appears on the command line.
- `create --encrypt` reads the password from the `SIMPLEZIP_PASSWORD` environment
  variable, or from an interactive terminal prompt where the input is not echoed. If
  neither is available, the command fails rather than proceed without a password.

## Activity Center

Every finished command is also recorded in the app's **Activity Center**, so a
`check`, `compare`, `create`, or `verify` run from the terminal shows up in the app's
history alongside the operations you started in the GUI.

## See also

- [URL scheme](./URL-SCHEME.md) — the `simplezip://` actions (`check`, `compare`, `open`).
- [Shortcuts & Siri](./SHORTCUTS.md) — App Intents automation.
- [Architecture](./ARCHITECTURE.md) — how the app, Core library, and backends fit together.
- [SECURITY.md](../SECURITY.md) — the project's security posture, including how passwords
  and untrusted archive input are handled.
