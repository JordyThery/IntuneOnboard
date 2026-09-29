#!/bin/sh
# uninstall.sh — remove Intune Onboard, its state and logs. Run as root.
# POSIX sh, so it also works when run as `sh uninstall.sh`.
set -u

if [ "$(id -u)" -ne 0 ]; then
    echo "uninstall.sh must run as root" >&2
    exit 10
fi

DAEMON_LABEL="be.jordythery.intuneonboard.daemon"
AGENT_LABEL="be.jordythery.intuneonboard.agent"

/bin/launchctl bootout "system/$DAEMON_LABEL" 2>/dev/null || true
# Every user session, including fast-user-switched ones.
/usr/bin/dscl . -list /Users UniqueID 2>/dev/null | /usr/bin/awk '$2 >= 501 { print $2 }' | while read -r uid; do
    /bin/launchctl bootout "gui/$uid/$AGENT_LABEL" 2>/dev/null || true
done

/bin/rm -f "/Library/LaunchDaemons/$DAEMON_LABEL.plist"
/bin/rm -f "/Library/LaunchAgents/$AGENT_LABEL.plist"
/bin/rm -rf "/Applications/Utilities/Intune Onboard.app"
/bin/rm -rf "/Library/Application Support/IntuneOnboard"
/bin/rm -rf /var/log/IntuneOnboard

# Per-user state.
for home in /Users/*; do
    [ -d "$home" ] || continue
    /bin/rm -rf "$home/Library/Application Support/IntuneOnboard"
done

/usr/sbin/pkgutil --forget be.jordythery.intuneonboard 2>/dev/null || true

echo "Intune Onboard removed."
exit 0
