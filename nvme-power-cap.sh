#!/bin/sh
case "$1" in
  post) /usr/bin/nvme set-feature /dev/nvme0 -f 0x02 --value=0x2 || true ;;
esac
