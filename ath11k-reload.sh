#!/bin/bash
# ath11k resume hang workaround: cold-init WiFi across suspend instead of resuming it
case "$1" in
  pre)  /usr/bin/systemctl stop iwd 2>/dev/null; /usr/sbin/modprobe -r ath11k_pci ath11k 2>/dev/null || true ;;
  post) /usr/sbin/modprobe ath11k_pci 2>/dev/null || true; /usr/bin/systemctl start iwd 2>/dev/null ;;
esac
exit 0
