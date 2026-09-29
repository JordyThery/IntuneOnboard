#!/bin/sh
# uninstall.sh — remove Intune Onboard completely. Run as root.
#
# Deliberately POSIX sh, not zsh. A technician reaching for this will type
# `sudo sh uninstall.sh` as often as `sudo ./uninstall.sh`, and the first
# form ignores the shebang — which is exactly how this failed on hardware,
# on the zsh-only glob qualifier below. An uninstaller is the worst place
# to be fussy about how it was invoked.
set -u

if [ "$(id -u)" -ne 0 ]; then
    echo "uninstall.sh must run as root" >&2
    exit 10
fi

DAEMON_LABEL="be.jordythery.intuneonboard.daemon"
AGENT_LABEL="be.jordythery.intuneonboard.agent"

/bin/launchctl bootout "system/$DAEMON_LABEL" 2>/dev/null || true
CONSOLE_UID="$(/usr/bin/stat -f %u /dev/console 2>/dev/null || echo 0)"
if [ "$CONSOLE_UID" -gt 0 ]; then
    /bin/launchctl bootout "gui/$CONSOLE_UID/$AGENT_LABEL" 2>/dev/null || true
fi

/bin/rm -f "/Library/LaunchDaemons/$DAEMON_LABEL.plist"
/bin/rm -f "/Library/LaunchAgents/$AGENT_LABEL.plist"
/bin/rm -rf "/Applications/Utilities/Intune Onboard.app"
/bin/rm -rf "/Library/Application Support/IntuneOnboard"
/bin/rm -rf /var/log/IntuneOnboard

# Per-user state (flattened path, per approved schema decision #6). The
# `[ -d ]` test stands in for zsh's `(N/)` qualifier: it skips /Users/.localized
# and copes with the glob matching nothing at all.
for home in /Users/*; do
    [ -d "$home" ] || continue
    /bin/rm -rf "$home/Library/Application Support/IntuneOnboard"
done

/usr/sbin/pkgutil --forget be.jordythery.intuneonboard 2>/dev/null || true

echo "Intune Onboard removed."
exit 0
