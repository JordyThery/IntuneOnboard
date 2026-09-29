#!/bin/zsh
# vendor-helpers.sh — fetch and pin the bundled third-party tools.
#
# Installomator: snapshot of the main branch (approved decision #8). The
# snapshot's SHA-256 is pinned in Vendor/Installomator/PINNED_SHA256 and the
# source commit recorded, so refreshing is a deliberate re-run of this script
# with a reviewable git diff — never a silent drift. Runtime `allowUpdate`
# remains tagged-releases-only and is handled by the daemon, not this script.
#
# dockutil / desktoppr / utiluti: latest GitHub release pkg, binary extracted,
# version + SHA-256 recorded. All Apache-2.0. Their LICENSE files are kept here
# in Vendor/<tool>/ and copied into the app by build-pkg.sh — the binaries land
# in Contents/Helpers bare, so nothing else would carry them.

set -euo pipefail

REPO_ROOT="${0:A:h:h}"
VENDOR="$REPO_ROOT/Vendor"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Prints "<tag> <pkg-download-url>" for the latest release.
github_latest_pkg() {
    curl -fsSL "https://api.github.com/repos/$1/releases/latest" | /usr/bin/python3 -c '
import json, sys
release = json.load(sys.stdin)
pkg = next(a for a in release["assets"] if a["name"].endswith(".pkg"))
print(release["tag_name"], pkg["browser_download_url"])
'
}

extract_pkg_binary() {
    # $1 pkg path, $2 binary name, $3 destination dir
    local expanded="$WORK/$2-expanded"
    rm -rf "$expanded"
    pkgutil --expand-full "$1" "$expanded"
    local binary
    binary="$(find "$expanded" -type f -name "$2" -perm +111 | head -1)"
    [[ -n "$binary" ]] || { echo "ERROR: $2 not found in pkg" >&2; return 1; }
    install -m 0755 "$binary" "$3/$2"
}

record() {
    # $1 dir, $2 file, $3 content
    print -r -- "$3" > "$1/$2"
}

# ---------------------------------------------------------------- Installomator
echo "==> Installomator (main snapshot)"
DEST="$VENDOR/Installomator"
mkdir -p "$DEST"
COMMIT="$(curl -fsSL "https://api.github.com/repos/Installomator/Installomator/commits/main" \
    | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["sha"])')"
curl -fsSL "https://raw.githubusercontent.com/Installomator/Installomator/$COMMIT/Installomator.sh" \
    -o "$DEST/Installomator.sh"
curl -fsSL "https://raw.githubusercontent.com/Installomator/Installomator/$COMMIT/LICENSE" \
    -o "$DEST/LICENSE"
chmod 0755 "$DEST/Installomator.sh"

# Sanity checks before pinning: the DEBUG default and version marker must
# still look the way our runtime handling assumes.
grep -qE '^DEBUG=' "$DEST/Installomator.sh" || { echo "ERROR: DEBUG= handling changed upstream" >&2; exit 21; }
grep -qE '^VERSION=' "$DEST/Installomator.sh" || { echo "ERROR: VERSION= marker missing" >&2; exit 21; }

SHA="$(shasum -a 256 "$DEST/Installomator.sh" | awk '{print $1}')"
record "$DEST" PINNED_SHA256 "$SHA"
record "$DEST" SOURCE_COMMIT "$COMMIT"
echo "    commit $COMMIT"
echo "    sha256 $SHA"

# ---------------------------------------------------------------- helpers
vendor_pkg_tool() {
    # $1 repo, $2 binary name
    local repo="$1" name="$2"
    echo "==> $name"
    local tag url
    read -r tag url <<< "$(github_latest_pkg "$repo")"
    local dest="$VENDOR/$name"
    mkdir -p "$dest"
    curl -fsSL "$url" -o "$WORK/$name.pkg"
    extract_pkg_binary "$WORK/$name.pkg" "$name" "$dest"
    curl -fsSL "https://raw.githubusercontent.com/$repo/HEAD/LICENSE" -o "$dest/LICENSE"
    record "$dest" VERSION "$tag"
    record "$dest" SHA256 "$(shasum -a 256 "$dest/$name" | awk '{print $1}')"
    echo "    $tag"
}

vendor_pkg_tool "kcrawford/dockutil" "dockutil"
vendor_pkg_tool "scriptingosx/desktoppr" "desktoppr"
vendor_pkg_tool "scriptingosx/utiluti" "utiluti"

echo "==> Done. Review the git diff before committing."
