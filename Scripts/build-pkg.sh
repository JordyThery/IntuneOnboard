#!/bin/zsh
# build-pkg.sh — archive, export, package, (optionally) sign and notarize.
#
# Identities come from the environment; nothing secret lives in the repo.
#   TEAM_ID                    e.g. ABCDE12345
#   DEVELOPER_ID_APP           "Developer ID Application: Name (TEAM)"
#   DEVELOPER_ID_INSTALLER     "Developer ID Installer: Name (TEAM)"
#   NOTARY_PROFILE             notarytool keychain profile name
#
# Without DEVELOPER_ID_* the script produces an UNSIGNED pkg for local testing.
# With them it signs; with NOTARY_PROFILE it also notarizes and staples.

set -euo pipefail

REPO_ROOT="${0:A:h:h}"
BUILD_DIR="$REPO_ROOT/build"
DIST_DIR="$REPO_ROOT/dist"
ARCHIVE_PATH="$BUILD_DIR/IntuneOnboard.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
PKG_ROOT="$BUILD_DIR/pkgroot"
IDENTIFIER="be.jordythery.intuneonboard"
# VERSION can be set in the environment to label a test build without having to
# tag first; releases still take it from the tag.
VERSION="${VERSION:-$(cd "$REPO_ROOT" && git describe --tags --always 2>/dev/null || echo 0.1.0)}"
# Tags are written v0.3.0; pkg and installer versions are compared as version
# numbers, so the leading "v" has to go.
VERSION="${VERSION#v}"

rm -rf "$BUILD_DIR" "$DIST_DIR"
mkdir -p "$BUILD_DIR" "$DIST_DIR"

echo "==> Verifying vendored Installomator"
"$REPO_ROOT/Scripts/verify-installomator.sh"

echo "==> Archiving (scheme IntuneOnboard)"
xcodebuild archive \
    -project "$REPO_ROOT/IntuneOnboard.xcodeproj" \
    -scheme IntuneOnboard \
    -destination "generic/platform=macOS" \
    -archivePath "$ARCHIVE_PATH" \
    ${TEAM_ID:+DEVELOPMENT_TEAM="$TEAM_ID"} \
    | tail -5

APP_IN_ARCHIVE="$ARCHIVE_PATH/Products/Applications/Intune Onboard.app"

# The four bundled tools are Apache-2.0, which asks that anyone we give a copy
# to also gets the licence. Our own tenant use is not distribution; handing the
# pkg to a client is. Installomator's licence already travels with its folder
# (Xcode copies the whole thing); the three Mach-O helpers in Contents/Helpers
# arrive bare, so their licences are placed here.
#
# Must run BEFORE the outer bundle is re-signed: the outer seal covers bundle
# contents, so anything added afterwards invalidates the signature. Kept out of
# Contents/Helpers on purpose — the helper re-signing loop globs that directory
# and would try to codesign a text file.
copy_vendor_licences() {
    local app="$1"
    local destination="$app/Contents/Resources/Licenses"
    mkdir -p "$destination"
    for tool in desktoppr dockutil utiluti; do
        local source="$REPO_ROOT/Vendor/$tool/LICENSE"
        if [[ ! -f "$source" ]]; then
            echo "ERROR: $tool ships in the app but $source is missing." >&2
            echo "       Apache-2.0 asks that recipients get the licence; refusing to build." >&2
            exit 1
        fi
        install -m 0644 "$source" "$destination/$tool-LICENSE.txt"
    done
    # Installomator's own copy is expected at Contents/Resources/Installomator;
    # if Xcode ever stops copying it, say so rather than shipping without it.
    if [[ ! -f "$app/Contents/Resources/Installomator/LICENSE" ]]; then
        echo "ERROR: Installomator ships without its LICENSE." >&2
        exit 1
    fi
    echo "==> Vendor licences placed in Contents/Resources/Licenses"
}

if [[ -n "${DEVELOPER_ID_APP:-}" ]]; then
    echo "==> Exporting with Developer ID"
    EXPORT_PLIST="$BUILD_DIR/exportOptions.plist"
    /usr/libexec/PlistBuddy -c "Clear dict" \
        -c "Add :method string developer-id" \
        -c "Add :teamID string ${TEAM_ID:?TEAM_ID required for signed export}" \
        "$EXPORT_PLIST" >/dev/null
    xcodebuild -exportArchive \
        -archivePath "$ARCHIVE_PATH" \
        -exportOptionsPlist "$EXPORT_PLIST" \
        -exportPath "$EXPORT_DIR" \
        | tail -5
    APP_PATH="$EXPORT_DIR/Intune Onboard.app"

    copy_vendor_licences "$APP_PATH"

    # Re-sign bundled Mach-O helpers (Contents/Helpers, arrives in M2+) with
    # our identity + hardened runtime so the whole bundle carries one signer.
    HELPERS_DIR="$APP_PATH/Contents/Helpers"
    if [[ -d "$HELPERS_DIR" ]]; then
        echo "==> Re-signing helpers"
        for helper in "$HELPERS_DIR"/*(N); do
            codesign --force --options runtime --timestamp \
                --sign "$DEVELOPER_ID_APP" "$helper"
        done
    fi

    # onboardd is a bare Mach-O, so codesign would name it after the file
    # ("onboardd") and PRODUCT_BUNDLE_IDENTIFIER has no effect. The XPC
    # requirement names this identifier explicitly — see
    # ServiceIdentity.daemonSigningIdentifier.
    echo "==> Re-signing onboardd as $IDENTIFIER.daemon"
    codesign --force --options runtime --timestamp \
        --identifier "$IDENTIFIER.daemon" \
        --sign "$DEVELOPER_ID_APP" "$APP_PATH/Contents/MacOS/onboardd"

    # Outer bundle last, so its seal covers the nested signatures above.
    codesign --force --options runtime --timestamp \
        --sign "$DEVELOPER_ID_APP" "$APP_PATH"

    # The app and the daemon enforce this requirement on each other over XPC
    # (CodeSigning.peerRequirement). An ad-hoc build has no Team ID and skips
    # the check, so a mismatch here is invisible until the day you sign — and
    # then it costs the retry path silently. Fail the build instead.
    echo "==> Verifying the XPC code-signing requirement"
    # Mirrors CodeSigning.peerRequirement. Note the identifiers are exact:
    # `identifier` does not take wildcards.
    XPC_REQUIREMENT="anchor apple generic and certificate leaf[subject.OU] = \"$TEAM_ID\" and (identifier \"$IDENTIFIER\" or identifier \"$IDENTIFIER.daemon\")"
    for binary in "$APP_PATH" "$APP_PATH/Contents/MacOS/onboardd"; do
        if ! codesign --verify -R="$XPC_REQUIREMENT" "$binary" 2>/dev/null; then
            echo "ERROR: $(basename "$binary") does not satisfy the XPC requirement:" >&2
            echo "       $XPC_REQUIREMENT" >&2
            echo "       signing identifier: $(codesign -dv "$binary" 2>&1 | sed -n 's/^Identifier=//p')" >&2
            exit 1
        fi
    done
else
    echo "==> No DEVELOPER_ID_APP set: using archive output unsigned"
    APP_PATH="$APP_IN_ARCHIVE"
    # Same layout in an unsigned local build, so what is tested is what ships.
    copy_vendor_licences "$APP_PATH"
fi

echo "==> Building payload"
mkdir -p "$PKG_ROOT/Applications/Utilities" "$PKG_ROOT/Library/LaunchDaemons" "$PKG_ROOT/Library/LaunchAgents"
ditto "$APP_PATH" "$PKG_ROOT/Applications/Utilities/Intune Onboard.app"
install -m 0644 "$REPO_ROOT/LaunchServices/$IDENTIFIER.daemon.plist" "$PKG_ROOT/Library/LaunchDaemons/"
install -m 0644 "$REPO_ROOT/LaunchServices/$IDENTIFIER.agent.plist" "$PKG_ROOT/Library/LaunchAgents/"

echo "==> pkgbuild"
COMPONENT_PKG="$BUILD_DIR/IntuneOnboard-component.pkg"
pkgbuild \
    --root "$PKG_ROOT" \
    --identifier "$IDENTIFIER" \
    --version "$VERSION" \
    --scripts "$REPO_ROOT/Scripts/pkg" \
    "$COMPONENT_PKG"

echo "==> productbuild"
FINAL_PKG="$DIST_DIR/IntuneOnboard-$VERSION.pkg"
if [[ -n "${DEVELOPER_ID_INSTALLER:-}" ]]; then
    productbuild --package "$COMPONENT_PKG" --sign "$DEVELOPER_ID_INSTALLER" "$FINAL_PKG"
else
    productbuild --package "$COMPONENT_PKG" "$FINAL_PKG"
    echo "    (unsigned — set DEVELOPER_ID_INSTALLER for a distributable pkg)"
fi

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    echo "==> Notarizing"
    # Capture the submission id so a rejection can be explained rather than
    # just reported: notarytool's own failure output names no reason, and the
    # log is the only place that does.
    SUBMISSION_LOG="$BUILD_DIR/notarization.json"
    if ! xcrun notarytool submit "$FINAL_PKG" \
            --keychain-profile "$NOTARY_PROFILE" \
            --wait --output-format json > "$SUBMISSION_LOG"; then
        echo "!!! notarytool submit failed:"
        cat "$SUBMISSION_LOG" || true
        exit 1
    fi

    SUBMISSION_ID=$(/usr/bin/plutil -extract id raw -o - "$SUBMISSION_LOG" 2>/dev/null || true)
    SUBMISSION_STATUS=$(/usr/bin/plutil -extract status raw -o - "$SUBMISSION_LOG" 2>/dev/null || true)
    echo "    submission $SUBMISSION_ID: $SUBMISSION_STATUS"

    if [[ "$SUBMISSION_STATUS" != "Accepted" ]]; then
        echo "!!! Not accepted. The reasons are in the notary log:"
        xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$NOTARY_PROFILE" || true
        exit 1
    fi

    xcrun stapler staple "$FINAL_PKG"
fi

# Say what was actually produced rather than leaving it to be assumed: an
# unsigned or unnotarized pkg installs fine by MDM and fails by hand, and
# that difference has cost an afternoon before.
echo "==> Verifying"
xcrun stapler validate "$FINAL_PKG" 2>/dev/null \
    && echo "    stapled: yes" \
    || echo "    stapled: no (Gatekeeper will need to reach Apple to check this pkg)"
spctl --assess --type install -vv "$FINAL_PKG" 2>&1 | sed 's/^/    /' || true

echo "==> Done: $FINAL_PKG"
