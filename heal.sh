#!/bin/sh
# nvme-power-cap self-healing installer. Verifies the 6W power-cap artefacts
# exist in BOTH slots /etc overlay uppers; reinstalls from /home masters if
# missing or drifted. Logs every run.
set -u
M=/home/.nvme-power-cap
LOG=$M/heal.log
log(){ echo "$(date -Is) $*" >> "$LOG"; }

install_into(){
  U="$1"; TAG="$2"; CH=0
  mkdir -p "$U/systemd/system/sysinit.target.wants" \
           "$U/systemd/system/timers.target.wants" \
           "$U/systemd/system/multi-user.target.wants" \
           "$U/systemd/system-sleep"
  for f in nvme-power-cap.service nvme-power-cap-heal.service nvme-power-cap-heal.timer cec-standby-poweroff.service; do
    cmp -s "$M/$f" "$U/systemd/system/$f" || { cp "$M/$f" "$U/systemd/system/$f"; CH=1; }
  done
  [ -L "$U/systemd/system/sysinit.target.wants/nvme-power-cap.service" ] || \
    { ln -sf ../nvme-power-cap.service "$U/systemd/system/sysinit.target.wants/nvme-power-cap.service"; CH=1; }
  [ -L "$U/systemd/system/timers.target.wants/nvme-power-cap-heal.timer" ] || \
    { ln -sf ../nvme-power-cap-heal.timer "$U/systemd/system/timers.target.wants/nvme-power-cap-heal.timer"; CH=1; }
  [ -L "$U/systemd/system/multi-user.target.wants/cec-standby-poweroff.service" ] || \
    { ln -sf ../cec-standby-poweroff.service "$U/systemd/system/multi-user.target.wants/cec-standby-poweroff.service"; CH=1; }
  for h in nvme-power-cap.sh ath11k-reload.sh; do
    [ -f "$M/$h" ] || continue
    cmp -s "$M/$h" "$U/systemd/system-sleep/$h" || \
      { cp "$M/$h" "$U/systemd/system-sleep/$h"; CH=1; }
    chmod 755 "$U/systemd/system-sleep/$h"
  done
  # sleep disabled until the platform s2idle resume hang is fixed: mask all
  # sleep targets so no path (GUI idle timer, button, menu) can suspend
  for t in sleep.target suspend.target suspend-then-hibernate.target hibernate.target; do
    [ "$(readlink "$U/systemd/system/$t" 2>/dev/null)" = /dev/null ] || \
      { ln -sf /dev/null "$U/systemd/system/$t"; CH=1; }
  done
  if [ "$CH" = 1 ]; then log "HEALED $TAG (artefacts reinstalled)"; else log "ok $TAG"; fi
}

# 1. running slot (live /var)
install_into /etc self

# 2. other slot
SELF=$(findmnt -no SOURCE /var 2>/dev/null)
OTHER=""
case "$SELF" in
  *nvme0n1p6) OTHER=/dev/nvme0n1p7 ;;
  *nvme0n1p7) OTHER=/dev/nvme0n1p6 ;;
esac
[ -z "$OTHER" ] && OTHER=$(readlink -f /dev/disk/by-partsets/other/var 2>/dev/null || true)
if [ -n "$OTHER" ] && [ -b "$OTHER" ]; then
  T=$(mktemp -d)
  if mount "$OTHER" "$T" 2>/dev/null; then
    install_into "$T/lib/overlays/etc/upper" "other($OTHER)"
    umount "$T"
  else
    log "WARN could not mount other var $OTHER"
  fi
  rmdir "$T"
else
  log "WARN other var partition not identified"
fi

# 3. re-assert the 6W cap right now
/usr/bin/nvme get-feature /dev/nvme0 -f 0x02 2>/dev/null | grep -q "Current value:0x00000002" || \
  { /usr/bin/nvme set-feature /dev/nvme0 -f 0x02 --value=0x2 >/dev/null 2>&1 && log "REAPPLIED 6W cap (was not ps2)"; }

# 4. ensure nvme.noacpi=1 on the live slot's kernel command line (clean NVMe
# shutdown across suspend). If an update stripped it, patch grub and
# regenerate; takes effect next boot. Sleep is masked meanwhile, so the
# unpatched window is safe.
if ! grep -q "nvme.noacpi=1" /proc/cmdline; then
  if grep -q "^GRUB_CMDLINE_LINUX_DEFAULT=" /etc/default/grub 2>/dev/null && \
     ! grep -q "nvme.noacpi=1" /etc/default/grub; then
    sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="nvme.noacpi=1 /' /etc/default/grub
  fi
  if command -v update-grub >/dev/null 2>&1 && grep -q "nvme.noacpi=1" /etc/default/grub 2>/dev/null; then
    update-grub >/dev/null 2>&1 && log "REPAIRED grub: nvme.noacpi=1 restored (effective next boot)"
  else
    log "WARN nvme.noacpi=1 missing from cmdline and could not repair grub"
  fi
fi

# keep log bounded
tail -n 200 "$LOG" > "$LOG.t" && mv "$LOG.t" "$LOG"
exit 0
