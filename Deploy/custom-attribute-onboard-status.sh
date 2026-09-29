#!/bin/zsh
# Intune custom attribute — reports Intune Onboard's state for this Mac.
#
# Devices → Scripts and remediations → macOS custom attributes.
#   Attribute type: String
#   Run script as signed-in user: NO (it must be root to read the device state)
#
# Whatever this prints on stdout becomes the attribute's value, verbatim, so
# it prints exactly one line and nothing else. It always exits 0: a non-zero
# exit is reported by Intune as a script failure, which is a different thing
# from "this Mac has not been provisioned" and would hide the latter.
#
# Example values:
#   provisioning: complete (4/4) · onboarding: complete (jordy)
#   provisioning: complete (4/4) · onboarding: in progress (jordy, 3/8)
#   provisioning: failed (1 failed, 4/4 finished) · onboarding: no console user
#   not installed

set -u

ONBOARDD="/Applications/Utilities/Intune Onboard.app/Contents/MacOS/onboardd"

if [[ ! -x "$ONBOARDD" ]]; then
    # The expected answer on a Mac the package has not reached yet, and the
    # one an administrator most needs to be able to filter on.
    echo "not installed"
    exit 0
fi

# Not named `status`: in zsh that is a read-only alias for $?, and assigning
# to it fails — which produced an empty attribute value for every Mac until a
# test caught it.
#
# stderr is discarded rather than merged: a warning on the way to a perfectly
# good answer must not end up inside the attribute's value.
summary=$("$ONBOARDD" status 2>/dev/null)

if [[ -z "$summary" ]]; then
    echo "unknown (onboardd produced no output)"
    exit 0
fi

# First line only, for the same reason.
echo "${summary%%$'\n'*}"
exit 0
