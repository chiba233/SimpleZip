SimpleZip optional RAR backend
==============================

RAR archive creation needs the official RARLAB command-line `rar` tool.
SimpleZip does not redistribute the RARLAB binary in public builds.

Before installing:

1. Read simplezip-rar-license-notice.txt in this folder.
2. Review the current RARLAB EULA:
   https://www.rarlab.com/license.htm
3. Install only if you accept the RARLAB terms.

To install for the current macOS user, run this script from Terminal:

    ./simplezip-install-rar-backend.sh

You can also run the installer from SimpleZip Settings after confirming that
you have read the README and license notice.

The script downloads the official macOS ARM and x64 RARLAB packages, combines
their `rar` executables into a universal binary, and writes it to:

    ~/Library/Application Support/SimpleZip/Tools/rar

SimpleZip checks that Application Support path in Automatic mode. The installed
binary is local user data, not part of the SimpleZip app bundle.
