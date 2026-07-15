#!/bin/bash
# steam-machine-nvme-fix installer
#
# Installs a boot-time NVMe power-state cap (plus a self-healing service that
# survives SteamOS A/B updates) onto a Steam Machine whose third-party NVMe
# drive brownouts under sustained write load.
#
# Run as root, either:
#   - on the booted SteamOS itself (live mode), or
#   - from the SteamOS recovery USB with the internal drive present
#     (recovery mode is detected automatically).
#
# USE AT YOUR OWN RISK. Probe your own drive's stable power state first;
# see README.md. Default is power state 2 (6W on a Sabrent Rocket 5).

set -euo pipefail

POWER_STATE="${POWER_STATE:-2}"
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
FILES=(heal.sh nvme-power-cap.service nvme-power-cap-heal.service nvme-power-cap-heal.timer nvme-power-cap.sh)

[[ $EUID -eq 0 ]] || { echo "Run as root."; exit 1; }
for f in "${FILES[@]}"; do [[ -f "$SRC_DIR/$f" ]] || { echo "Missing $f next to install.sh"; exit 1; }; done

seed_overlay() { # $1 = path to a var partition's overlay upper root
    local U="$1"
    mkdir -p "$U/systemd/system/sysinit.target.wants" \
             "$U/systemd/system/timers.target.wants" \
             "$U/systemd/system-sleep"
    cp "$SRC_DIR/nvme-power-cap.service"      "$U/systemd/system/"
    cp "$SRC_DIR/nvme-power-cap-heal.service" "$U/systemd/system/"
    cp "$SRC_DIR/nvme-power-cap-heal.timer"   "$U/systemd/system/"
    cp "$SRC_DIR/nvme-power-cap.sh"           "$U/systemd/system-sleep/"
    chmod 755 "$U/systemd/system-sleep/nvme-power-cap.sh"
    ln -sf ../nvme-power-cap.service      "$U/systemd/system/sysinit.target.wants/nvme-power-cap.service"
    ln -sf ../nvme-power-cap-heal.timer   "$U/systemd/system/timers.target.wants/nvme-power-cap-heal.timer"
}

install_masters() { # $1 = mounted home partition root
    local H="$1/.nvme-power-cap"
    mkdir -p "$H"
    for f in "${FILES[@]}"; do cp "$SRC_DIR/$f" "$H/"; done
    chown -R root:root "$H"
    chmod 755 "$H" "$H/heal.sh" "$H/nvme-power-cap.sh"
    chmod 644 "$H"/*.service "$H"/*.timer
}

if findmnt -no SOURCE /home | grep -q partsets || findmnt -no SOURCE /home | grep -qE 'nvme.*p8'; then
    echo ":: Live SteamOS detected"
    install_masters /home
    seed_overlay /var/lib/overlays/etc/upper
    # other slot's var
    SELF=$(findmnt -no SOURCE /var)
    case "$SELF" in
        *p6) OTHER=$(echo "$SELF" | sed 's/p6$/p7/');;
        *p7) OTHER=$(echo "$SELF" | sed 's/p7$/p6/');;
        *)   OTHER="";;
    esac
    if [[ -n "$OTHER" && -b "$OTHER" ]]; then
        T=$(mktemp -d); mount "$OTHER" "$T"
        seed_overlay "$T/lib/overlays/etc/upper"
        umount "$T"; rmdir "$T"
    fi
    systemctl daemon-reload
    systemctl enable --now nvme-power-cap.service nvme-power-cap-heal.timer
    nvme set-feature /dev/nvme0 -f 0x02 --value="0x$POWER_STATE" || true
    echo ":: Installed. Cap active now and on every boot/resume; heal timer running."
else
    echo ":: Recovery mode - mounting internal drive by partition label"
    T=$(mktemp -d)
    mount /dev/disk/by-partlabel/home "$T"
    install_masters "$T"
    umount "$T"
    for V in var-A var-B; do
        mount "/dev/disk/by-partlabel/$V" "$T"
        seed_overlay "$T/lib/overlays/etc/upper"
        umount "$T"
    done
    rmdir "$T"
    echo ":: Installed to both slots. Remove the USB and boot the internal drive."
fi
