#!/usr/bin/env bash
set -euo pipefail

# verify_appcast.sh — pre-release self-check.
#
# What it does:
#   1. Reads docs/appcast.xml from the working tree (matches what GitHub's
#      raw.githubusercontent.com serves to users once main is pushed).
#   2. Extracts the latest item's <enclosure> url + sparkle:edSignature.
#   3. Downloads the DMG from that URL to /tmp.
#   4. Runs `sign_update --verify` against the local Keychain entry
#      (account "simplezip-ci"), which holds the matching public key.
#
# Exit 0 if signature checks out (= what a Sparkle-installed user on 0.1.10+
# will see). Non-zero otherwise, with a human-readable reason.
#
# Why local file → remote DMG:
#   The local file is what main commits and what raw.githubusercontent.com
#   will serve; the remote DMG is what the GitHub Releases CDN serves.
#   Catching disagreement between the two is exactly the kind of "publishing
#   slipped" bug this script exists to find before users see it.
#
# Prereqs:
#   - macOS Keychain has the "simplezip-ci" account populated (i.e. you ran
#     `generate_keys --account simplezip-ci` at some point on this machine).
#     If you don't, import from secrets/sparkle_ed_private_key.txt via
#     `generate_keys --account simplezip-ci -f secrets/sparkle_ed_private_key.txt`.
#   - The Xcode project has been built at least once locally OR the SwiftPM
#     `.build/xcode-dmg/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update`
#     path exists — needed to find the sign_update binary.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APPCAST_PATH="${APPCAST_PATH:-$ROOT_DIR/docs/appcast.xml}"
KEYCHAIN_ACCOUNT="${SPARKLE_KEYCHAIN_ACCOUNT:-simplezip-ci}"

# --- locate sign_update -------------------------------------------------------

find_sign_update() {
  # Order of preference matches "wherever Xcode / SwiftPM actually put it":
  local candidates=(
    "$ROOT_DIR/.build/xcode-dmg/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update"
  )
  for c in "${candidates[@]}"; do
    if [[ -x "$c" ]]; then
      echo "$c"
      return 0
    fi
  done
  # Fallback: search Xcode's default DerivedData. Works for maintainer's
  # machine where the Xcode project has been opened normally.
  local found
  found=$(find ~/Library/Developer/Xcode/DerivedData -path '*sparkle*/bin/sign_update' -type f 2>/dev/null | head -1)
  if [[ -n "$found" ]]; then
    echo "$found"
    return 0
  fi
  return 1
}

SIGN_UPDATE=$(find_sign_update || true)
if [[ -z "${SIGN_UPDATE:-}" ]]; then
  echo "ERROR: sign_update binary not found." >&2
  echo "       Open SimpleZip.xcodeproj in Xcode once (or run a Release build) so" >&2
  echo "       Sparkle's SPM artifact gets resolved, then re-run this script." >&2
  exit 1
fi

# --- parse appcast ------------------------------------------------------------

if [[ ! -f "$APPCAST_PATH" ]]; then
  echo "ERROR: appcast not found at $APPCAST_PATH" >&2
  exit 1
fi

# Take the first <enclosure ... /> — that's the latest release in RSS order.
ENCLOSURE_LINE=$(awk '/<enclosure/,/\/>/' "$APPCAST_PATH" | tr -d '\n')
if [[ -z "$ENCLOSURE_LINE" ]]; then
  echo "ERROR: no <enclosure> found in $APPCAST_PATH" >&2
  exit 1
fi

extract_attr() {
  # extract_attr <key> <text> -> value, or empty string if missing.
  # `|| true` is required because under `set -euo pipefail`, a grep that finds
  # no match returns 1, which would otherwise kill the script silently inside
  # the `$(...)` substitution before we get to the "missing field" check.
  local key="$1" text="$2"
  echo "$text" | grep -oE "${key}=\"[^\"]*\"" | head -1 | sed -E "s/${key}=\"//; s/\"$//" || true
}

URL=$(extract_attr "url" "$ENCLOSURE_LINE")
SIG=$(extract_attr "sparkle:edSignature" "$ENCLOSURE_LINE")
LENGTH=$(extract_attr "length" "$ENCLOSURE_LINE")
VERSION=$(extract_attr "sparkle:shortVersionString" "$ENCLOSURE_LINE")

if [[ -z "$URL" ]]; then
  echo "ERROR: <enclosure> missing url attribute" >&2
  exit 1
fi
if [[ -z "$SIG" ]]; then
  echo "ERROR: <enclosure> for v${VERSION:-?} missing sparkle:edSignature." >&2
  echo "       This is the bug Sparkle EdDSA was added to prevent — any" >&2
  echo "       0.1.10+ client would refuse this update with \"could not" >&2
  echo "       verify authenticity\"." >&2
  exit 1
fi

echo "Latest appcast item: v${VERSION:-?}"
echo "  URL:    $URL"
echo "  Length: ${LENGTH:-?}"
echo "  Sig:    ${SIG:0:24}..."

# --- download DMG -------------------------------------------------------------

TMP_DIR=$(mktemp -d -t simplezip-verify-appcast)
trap 'rm -rf "$TMP_DIR"' EXIT
DMG_PATH="$TMP_DIR/update.dmg"

echo ""
echo "Downloading DMG to $DMG_PATH ..."
if ! curl -L --fail --silent --show-error --output "$DMG_PATH" "$URL"; then
  echo "ERROR: failed to download $URL" >&2
  exit 1
fi

ACTUAL_LENGTH=$(stat -f%z "$DMG_PATH")
echo "  Downloaded $ACTUAL_LENGTH bytes."
if [[ -n "$LENGTH" && "$ACTUAL_LENGTH" != "$LENGTH" ]]; then
  # Sparkle treats length as advisory; this is still a strong "something is wrong"
  # signal — either the appcast was generated against a different DMG or the CDN
  # is serving truncated bytes.
  echo "ERROR: downloaded length ($ACTUAL_LENGTH) doesn't match appcast length ($LENGTH)." >&2
  exit 1
fi

# --- verify -------------------------------------------------------------------

echo ""
echo "Verifying signature with sign_update (Keychain account: $KEYCHAIN_ACCOUNT) ..."
if "$SIGN_UPDATE" --verify --account "$KEYCHAIN_ACCOUNT" "$DMG_PATH" "$SIG"; then
  echo ""
  echo "OK: appcast signature verifies against $KEYCHAIN_ACCOUNT public key."
  echo "    A Sparkle-installed user on 0.1.10+ will accept this update."
  exit 0
else
  rc=$?
  echo "" >&2
  echo "ERROR: sign_update --verify exited with status $rc." >&2
  echo "       Either the appcast signature is wrong, the DMG bytes don't match" >&2
  echo "       what was signed in CI, or your local Keychain doesn't have the" >&2
  echo "       matching public key under account '$KEYCHAIN_ACCOUNT'." >&2
  exit "$rc"
fi
