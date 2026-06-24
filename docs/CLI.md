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
  ready-to-copy `sudo` command to create the link yourself:

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
  simplezip list <archive>                   List an archive's entries (path, size, kind)
  simplezip check <archive>...               Test archive integrity (exit 1 on any failure)
  simplezip inspect <archive>                Release-package check (no extract; exit 1 if suspicious paths)
  simplezip compare <left> <right>           Compare two archives (exit 1 when different)
  simplezip create <output> <input>... [options]
                                             Create an archive; format from the output extension
  simplezip extract <archive>... [--to DIR]  Extract into a uniquely named folder (safe path)
  simplezip verify <checksum-file>...        Verify SHA256SUMS / checksums.txt / .sha256 / .md5 / .sfv
  simplezip hash <file>... [--algo LIST]     Compute checksums (CRC32/MD5/SHA1/SHA256/SHA512; default SHA256)
  simplezip space <archive>                  Disk-usage breakdown (largest files/folders/extensions, ratio)
  simplezip rescue <archive> [--to DIR]      Best-effort data recovery from a damaged archive
  simplezip checkup <archive>...             Batch health check (test + suspicious/junk/encrypted counts)
  simplezip duplicates <path>...             Find duplicate archives by structural fingerprint
  simplezip reproduce <folder> [--format F]  Pack a folder twice and check byte-identical reproducibility
  simplezip audit <folder>                   Audit a release directory (checksum coverage, orphans, stale refs)
  simplezip verify-group <folder>            Quick name-only release-group check (is it verifiable?)
  simplezip doctor                           Check the CLI environment (app, backends, symlink)
  simplezip completions <zsh|bash|fish>      Print a shell completion script to stdout
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

### `completions`

```
simplezip completions <zsh|bash|fish>
```

Prints a shell completion script to stdout for the given shell — `zsh`, `bash`, or `fish`. It completes the subcommands,
the global options, and `create`'s options. It writes nothing to disk; pipe or redirect it where your shell expects
completions, for example:

```
simplezip completions zsh > "${fpath[1]}/_simplezip"          # zsh
simplezip completions bash > /usr/local/etc/bash_completion.d/simplezip
simplezip completions fish > ~/.config/fish/completions/simplezip.fish
```

An unrecognized shell name exits `2`.

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

Shows the top-level help, or detailed help for one command. An unknown command exits `2` and, when it's close to a real
one, suggests it — `unknown command: verfy (did you mean "verify"?)`.

### `list`

```
simplezip list <archive> [--json] [--quiet]
```

Lists an archive's entries. Plain-text output is one line per entry, `kind  size  name`
(`d` for directories, `-` for files). Read-only. Encrypted archives prompt for a password
(or read `SIMPLEZIP_PASSWORD`). With `--json` the object carries `count` and an `entries`
array of `{ name, size, directory }`.

### `inspect`

```
simplezip inspect <archive> [--json] [--quiet]
```

The Release Assistant's package check, without extracting: file/folder counts, total size,
macOS junk, empty directories, executables, symlinks, and suspicious entry paths (path
traversal, absolute paths, …). **Exit `1`** when suspicious paths are found, `0` when clean.
Encrypted archives prompt for a password. For a content-level checksum check, use `verify`.

### `space`

```
simplezip space <archive> [--json] [--quiet]
```

Disk-usage breakdown: original vs packed size and compression ratio, macOS-junk bytes, and
the largest files / top-level folders / extensions. Read-only; prompts for a password on
encrypted archives.

### `hash`

```
simplezip hash <file>... [--algo LIST] [--json] [--quiet]
```

Computes checksums for files (or every file inside a folder, recursively). `--algo`/`-a`
is a comma-separated list, or `all`; names are case- and hyphen-insensitive (`sha-256` =
`SHA256`). Choices: `CRC32, MD5, SHA1, SHA256, SHA512`. Defaults to `SHA256`. Output is
BSD-tag style — `SHA256 (path) = hex` — which `verify` can read back. **Exit `1`** if any
file cannot be read.

```sh
simplezip hash --algo all *.zip > SHA256SUMS && simplezip verify SHA256SUMS
```

### `duplicates`

```
simplezip duplicates <path>... [--json] [--quiet]
```

Finds duplicate archives among the given archives (or every archive inside a folder, when
a single directory is given). Groups by structural fingerprint (identical path/size/CRC
structure), then by matching entry-count-and-size. Read-only; not-listable archives are
skipped and reported. Always exits `0`.

### `extract`

```
simplezip extract <archive>... [--to DIR] [--json] [--quiet]
```

Extracts each archive into a uniquely named folder (never overwriting), the same vetted
path Finder auto-extract uses — untrusted-entry safety checks, staging and conflict
handling included. `--to`/`-d` sets the destination parent (must be an existing folder;
defaults to each archive's own folder). Encrypted archives prompt for a password (after
trying `SIMPLEZIP_PASSWORD`, then your saved preset / session password). **Exit `1`** if
any archive fails.

### `rescue`

```
simplezip rescue <archive> [--to DIR] [--json] [--quiet]
```

Best-effort recovery from a **damaged** archive: pulls out whatever still reads into a new
`<name> (rescued)` folder (never overwriting; the original is never touched). Rescued files
may be incomplete and the archive is **not** repaired; recovered output still passes the
untrusted-entry safety checks. `--to`/`-d` sets the parent folder. **Exit `1`** if nothing
could be recovered.

### `checkup`

```
simplezip checkup <archive>... [--json] [--quiet]
```

Batch health check across several archives (or every archive inside a folder, when a
single directory is given): per archive an integrity test plus file count, total size, and
suspicious-path / macOS-junk / encrypted-entry counts, then a summary line. Runs
unattended — archives whose entry names need a password are marked *not listable* rather
than prompting. **Exit `1`** if any archive fails its integrity test.

### `reproduce`

```
simplezip reproduce <folder> [--format zip|7z] [--json] [--quiet]
```

Packs the folder twice with reproducible settings and reports whether the two archives are
byte-for-byte identical (SHA-256), plus which factors are normalized / stripped /
stored-as-is. Only `zip` and `7z` support reproducible output (default `zip`). Temporary
archives are written to the system temp dir and cleaned up. **Exit `1`** when the two
builds differ.

### `audit`

```
simplezip audit <folder> [--json] [--quiet]
```

Audits a release directory by name + checksum file (no hashing): classifies artifacts /
checksums / signed containers / public keys / VERIFY docs, then reports SHA256SUMS coverage
gaps and stale entries, file names referenced by `VERIFY*.md` that are missing, and orphan
files. **Exit `1`** if any artifact is left uncovered by SHA256SUMS. For a content-level
check, use `verify`.

### `verify-group`

```
simplezip verify-group <folder> [--json] [--quiet]
```

A fast, name-only snapshot of a release folder's composition: whether it has a downloadable
artifact or signed container, a SHA256SUMS, a public key and a VERIFY doc — and whether a
downloader could verify it (artifact/container + checksums). Reads nothing. **Exit `1`**
when it isn't verifiable.

## Passwords

Passwords are **never** accepted as command-line arguments.

- `check`, `list`, `inspect`, `space`, `extract`, `rescue` handle an encrypted archive by
  first trying `SIMPLEZIP_PASSWORD` (so scripts never see a dialog), then prompting with a
  small no-echo dialog (up to three tries). The password is fed straight to the engine and
  never appears on the command line.
- `checkup` and `duplicates` run unattended over many archives, so they **never** prompt —
  an archive whose entry names need a password is marked *not listable* / skipped instead.
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
