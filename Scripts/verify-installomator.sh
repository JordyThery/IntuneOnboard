#!/bin/zsh
# verify-installomator.sh — check the vendored Installomator against its pin.
# Exits 21 on a checksum mismatch or changed DEBUG handling. Run by
# build-pkg.sh.

set -euo pipefail

REPO_ROOT="${0:A:h:h}"
DIR="$REPO_ROOT/Vendor/Installomator"
SCRIPT="$DIR/Installomator.sh"
PIN="$DIR/PINNED_SHA256"

[[ -f "$SCRIPT" && -f "$PIN" ]] || { echo "ERROR: vendored Installomator missing — run Scripts/vendor-helpers.sh" >&2; exit 20; }

ACTUAL="$(shasum -a 256 "$SCRIPT" | awk '{print $1}')"
EXPECTED="$(cat "$PIN")"
if [[ "$ACTUAL" != "$EXPECTED" ]]; then
    echo "ERROR: Installomator.sh SHA-256 mismatch" >&2
    echo "  expected: $EXPECTED" >&2
    echo "  actual:   $ACTUAL" >&2
    echo "  If this change is intentional, re-run Scripts/vendor-helpers.sh and commit the diff." >&2
    exit 21
fi

# The runtime appends DEBUG=0 and relies on the last assignment winning.
grep -qE '^DEBUG=' "$SCRIPT" || { echo "ERROR: DEBUG= default missing from Installomator.sh" >&2; exit 21; }
grep -qE 'eval' "$SCRIPT" || { echo "ERROR: argument eval handling changed in Installomator.sh" >&2; exit 21; }

echo "Installomator verified: $ACTUAL"
