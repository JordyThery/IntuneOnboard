#!/bin/zsh
# make-example-profile.sh — generate the example .mobileconfig from the
# annotated example .plist. DeployExampleTests fails if the two differ.

set -euo pipefail

REPO_ROOT="${0:A:h:h}"
PLIST="$REPO_ROOT/Deploy/be.jordythery.intuneonboard.example.plist"
PROFILE="$REPO_ROOT/Deploy/be.jordythery.intuneonboard.example.mobileconfig"

/usr/bin/env python3 - "$PLIST" "$PROFILE" <<'PYTHON'
import plistlib
import sys

source, destination = sys.argv[1], sys.argv[2]
domain = "be.jordythery.intuneonboard"

# Fixed UUIDs: a new UUID makes MDM treat the profile as a different one.
payload_uuid = "B7E4D9C1-3F62-4A8E-9D05-7C1E4B2A6F31"
profile_uuid = "A1C83E57-9B04-42D6-8E7F-2D5B60C9A814"

with open(source, "rb") as handle:
    settings = plistlib.load(handle)

payload = dict(settings)
payload.update({
    "PayloadType": domain,
    "PayloadIdentifier": f"{domain}.settings",
    "PayloadUUID": payload_uuid,
    "PayloadDisplayName": "Intune Onboard settings (example)",
    "PayloadVersion": 1,
})

profile = {
    "PayloadContent": [payload],
    "PayloadType": "Configuration",
    "PayloadIdentifier": f"{domain}.example",
    "PayloadUUID": profile_uuid,
    "PayloadDisplayName": "Intune Onboard (example — every key)",
    "PayloadOrganization": "Contoso",
    "PayloadDescription": (
        "Every available Intune Onboard setting. The annotated version, with a "
        "comment on each key, is be.jordythery.intuneonboard.example.plist."
    ),
    "PayloadScope": "System",
    "PayloadVersion": 1,
    "PayloadRemovalDisallowed": False,
}

with open(destination, "wb") as handle:
    plistlib.dump(profile, handle, fmt=plistlib.FMT_XML, sort_keys=True)
PYTHON

/usr/bin/plutil -lint "$PROFILE"
echo "==> wrote $PROFILE"
