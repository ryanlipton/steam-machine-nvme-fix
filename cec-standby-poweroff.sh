#!/bin/sh
# Turn the TV's "off" into a clean shutdown.
#
# When the TV goes to standby it sends a CEC standby message, and SteamOS
# responds by asking logind to suspend. On this machine suspend is masked (the
# platform s2idle resume hang), so the request is refused and the console just
# stays on with the TV dark. This watches for that refusal and powers off
# instead.
#
# Self-limiting by design: the trigger only exists because suspend is masked.
# If Valve fixes resume and the masks come off, standby succeeds, the refusal
# never appears, and this service quietly never fires again.
set -u

journalctl -f -n0 -o cat 2>/dev/null | while IFS= read -r line; do
    case "$line" in
        *"Failed to standby"*)
            logger -t cec-standby-poweroff "TV requested standby; powering off"
            systemctl poweroff
            ;;
    esac
done
