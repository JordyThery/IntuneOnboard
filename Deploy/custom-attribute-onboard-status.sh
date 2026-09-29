#!/bin/zsh
# Intune custom attribute: Intune Onboard status for this Mac.
#
# Devices → Scripts and remediations → macOS custom attributes.
#   Attribute type: String
#   Run script as signed-in user: No
#
# Prints one line and always exits 0. Example values:
#   provisioning: complete (4/4) · onboarding: complete (jordy)
#   provisioning: complete (4/4) · onboarding: in progress (jordy, 3/8)
#   provisioning: failed (1 failed, 4/4 finished) · onboarding: no console user
#   not installed

set -u

ONBOARDD="/Applications/Utilities/Intune Onboard.app/Contents/MacOS/onboardd"

if [[ ! -x "$ONBOARDD" ]]; then
    echo "not installed"
    exit 0
fi

# Not `status`, which is read-only in zsh. stderr is discarded to keep the
# value to a single line.
summary=$("$ONBOARDD" status 2>/dev/null)

if [[ -z "$summary" ]]; then
    echo "unknown (onboardd produced no output)"
    exit 0
fi

# First line only.
echo "${summary%%$'\n'*}"
exit 0
