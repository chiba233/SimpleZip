#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
INSTALLER="${ROOT_DIR}/SimpleZip/Tools/RARInstall/simplezip-install-rar-backend.sh"

if [[ ! -x "${INSTALLER}" ]]; then
    echo "error: installer is not executable at ${INSTALLER}" >&2
    exit 1
fi

exec "${INSTALLER}" "$@"
