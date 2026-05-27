This directory contains command-line archive backends used by SimpleZip development builds.

Current checked-in bundled binary:

```text
SimpleZip/Tools/7zz
```

The checked-in binary is the official 7-Zip 26.01 macOS universal `7zz` build with both `x86_64` and `arm64` slices.
Keep `7zip-License.txt` and `7zip-readme.txt` next to it so the app bundle carries the upstream notices.

Accepted app bundle paths:

```text
Contents/Resources/7zz
Contents/Resources/Tools/7zz
```

The app also accepts `7z` in the same locations, but `7zz` is preferred.

## Optional local RAR backend

RAR creation needs the official RARLAB `rar` command-line tool. The app already searches these bundled paths:

```text
Contents/Resources/rar
Contents/Resources/Tools/rar
```

For local development, install a universal `rar` binary into SimpleZip's user data directory:

```bash
./scripts/install_rar_backend.sh
```

The script downloads the official RARLAB macOS ARM and x64 packages, combines their `rar` executables with `lipo`, and
writes:

```text
~/Library/Application Support/SimpleZip/Tools/rar
```

Automatic RAR backend mode checks that Application Support path before system locations. The app still accepts
`Contents/Resources/rar` and `Contents/Resources/Tools/rar` for manually packaged bundles that have explicit
redistribution rights, but public SimpleZip builds should not include the proprietary RARLAB binary.

`SimpleZip/Tools/rar` and extracted RARLAB notices are intentionally ignored by git. RARLAB `rar` is
proprietary/shareware, and the RARLAB license does not allow redistributing the trial command-line package as part of
another package without permission. Keep it local unless you have redistribution rights.
