This directory contains the bundled 7-Zip backend used by SimpleZip development builds.

Current bundled binary:

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
