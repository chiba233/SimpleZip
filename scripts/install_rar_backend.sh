#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TOOLS_DIR="${ROOT_DIR}/SimpleZip/Tools"
RAR_VERSION="${RAR_VERSION:-722}"
RAR_BASE_URL="${RAR_BASE_URL:-https://www.rarlab.com/rar}"

ARM_ARCHIVE="rarmacos-arm-${RAR_VERSION}.tar.gz"
X64_ARCHIVE="rarmacos-x64-${RAR_VERSION}.tar.gz"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/simplezip-rar.XXXXXX")"
cleanup() {
    rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

download() {
    local archive_name="$1"
    local destination="$2"

    echo "Downloading ${archive_name}..."
    /usr/bin/curl --fail --location --show-error \
        "${RAR_BASE_URL}/${archive_name}" \
        --output "${destination}"
}

extract_package() {
    local archive_path="$1"
    local destination="$2"

    mkdir -p "${destination}"
    /usr/bin/tar -xzf "${archive_path}" -C "${destination}"

    if [[ ! -x "${destination}/rar/rar" ]]; then
        echo "error: expected executable not found at ${destination}/rar/rar" >&2
        exit 1
    fi
}

copy_first_existing_notice() {
    local source_root="$1"
    local destination_name="$2"
    shift 2

    local candidate
    for candidate in "$@"; do
        if [[ -f "${source_root}/rar/${candidate}" ]]; then
            cp "${source_root}/rar/${candidate}" "${TOOLS_DIR}/${destination_name}"
            return
        fi
    done
}

mkdir -p "${TOOLS_DIR}"

download "${ARM_ARCHIVE}" "${WORK_DIR}/${ARM_ARCHIVE}"
download "${X64_ARCHIVE}" "${WORK_DIR}/${X64_ARCHIVE}"

extract_package "${WORK_DIR}/${ARM_ARCHIVE}" "${WORK_DIR}/arm"
extract_package "${WORK_DIR}/${X64_ARCHIVE}" "${WORK_DIR}/x64"

echo "Creating universal SimpleZip/Tools/rar..."
/usr/bin/lipo -create \
    "${WORK_DIR}/arm/rar/rar" \
    "${WORK_DIR}/x64/rar/rar" \
    -output "${TOOLS_DIR}/rar"

chmod 755 "${TOOLS_DIR}/rar"

copy_first_existing_notice "${WORK_DIR}/arm" "rar-license.txt" \
    "license.txt" "License.txt" "LICENSE.txt"
copy_first_existing_notice "${WORK_DIR}/arm" "rar-readme.txt" \
    "readme.txt" "ReadMe.txt" "README.txt" "rar.txt"

echo
echo "Installed local RAR backend:"
/usr/bin/file "${TOOLS_DIR}/rar"
"${TOOLS_DIR}/rar" | /usr/bin/sed -n '1,3p'
echo
echo "Note: RARLAB rar is proprietary/shareware. The generated local backend is ignored by git."
echo "Verify redistribution rights with RARLAB before shipping it inside a public app package."
