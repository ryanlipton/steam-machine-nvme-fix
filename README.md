# steam-machine-nvme-fix

Workarounds for running a Valve Steam Machine (2026) with a high-power PCIe
Gen5 NVMe drive, with a self-healing installer that survives SteamOS A/B
updates.

**These are workarounds, not fixes.** Two of the three problems here belong to
the vendors: a slot that cannot deliver the power a Gen5 drive asks for, and a
platform suspend bug that hangs the machine on wake. Both are reported (Valve
ticket for the machine, feature request to Sabrent for the drive). Everything
in this repo exists to make the console reliable in the meantime, and each
piece is built to retire itself when the real fix arrives: the power cap
becomes unnecessary if the slot's budget is raised or you fit a lower-power
drive, and the sleep and HDMI-CEC workarounds stop firing the moment suspend is
safe to re-enable.

**In plain English:** you upgraded your Steam Machine with a fast Gen5 SSD and
now it won't install SteamOS, or it freezes at the splash screen, and the drive
seems to just vanish. The drive is fine. The Steam Machine's M.2 slot can't
feed it enough power when it writes at full speed, so it browns out like a
kettle tripping the fuse. This repo tells the drive to sip 6W instead of 11.5W,
applies that on every boot and wake, and quietly repairs itself after SteamOS
updates so the fix never disappears. Full write speed drops but stays at a
very quick 2.1 GB/s, and everything else works exactly as normal.

## The problem

The Steam Machine's M.2 slot cannot sustain the write-load power draw of some
high-power PCIe Gen5 NVMe drives (tested: Sabrent Rocket 5 2TB, Phison E26,
rated 11.5W at power state 0). Under any sustained write the drive brownouts
and drops off the PCIe bus:

    nvme nvme0: controller is down; will reset: CSTS=0xffffffff, PCI_STATUS=0x10
    nvme nvme0: Disabling device after reset failure: -19

Symptoms: fresh SteamOS installs fail at the imaging or sanitize step, cloned
systems hang at the splash screen during first-boot writes, and the drive's
SMART `unsafe_shutdowns` counter increments on every event. The drive itself is
healthy and works normally in hosts with stronger M.2 power delivery.

It is not thermal (zero seconds at critical temperature), not signal integrity
(all PCIe AER counters zero), and not fixable with the usual
`nvme_core.default_ps_max_latency_us=0 pcie_aspm=off pcie_port_pm=off`
parameters (APST governs idle states, not the active write draw).

## The fix

Cap the drive's operational power state so its write transient stays inside
what the slot can deliver. On the Rocket 5, power state 2 (6W) is fully stable
at 2.1 GB/s sequential writes; power state 1 (8W) still brownouts. One command:

    nvme set-feature /dev/nvme0 -f 0x02 --value=0x2

Two catches make this non-trivial to keep applied:

1. **It cannot persist.** The drive rejects saving the feature
   (`Feature Identifier Not Saveable`), and the kernel's NVMe controller reset
   at boot (and on resume from sleep) reverts it. Any pre-boot or firmware-level
   setting is wiped the moment the OS initialises the controller, so the cap
   must be re-applied by the OS after every controller reset.
2. **SteamOS A/B updates remove it.** OS updates install a fresh image to the
   inactive slot and switch to it; a per-image systemd unit is silently orphaned
   and the machine black-screens on the next update.

## What this repo installs

| File | Where it lives | What it does |
|---|---|---|
| `nvme-power-cap.service` | `/etc` overlay upper on both var slots | Applies the cap early every boot (`DefaultDependencies=no`, before `local-fs-pre.target`) |
| `nvme-power-cap.sh` | `systemd/system-sleep/` (both slots) | Re-applies the cap after every suspend/resume |
| `heal.sh` + masters | `/home/.nvme-power-cap/` (shared partition, survives updates) | Verifies all artefacts on **both** slots, reinstalls anything an update removed, re-asserts the cap, re-asserts `nvme.noacpi=1` in grub, keeps the sleep-target masks in place, logs every run |
| `ath11k-reload.sh` | `systemd/system-sleep/` (both slots) | Cold-inits the Wi-Fi card across suspend (resume-hang workaround; inert while sleep is masked) |
| `cec-standby-poweroff.service` + `.sh` | `/etc` overlay on both slots, script in `/home/.nvme-power-cap/` | Turns the TV's "off" into a clean shutdown instead of a blocked sleep (see below) |
| `nvme-power-cap-heal.service` + `.timer` | `/etc` overlay upper on both slots | Runs heal 2 minutes after boot and every 6 hours |

The key mechanism: SteamOS mounts `/etc` as an overlay whose writable layer
lives on the per-slot `/var` partition (`/var/lib/overlays/etc/upper`), and
`/var` and `/home` are preserved across A/B rootfs updates. Units installed
through the overlay survive updates; the heal timer repairs either slot if an
update ever removes them.

## Install

    sudo bash install.sh

Works from the booted SteamOS or from the recovery USB environment (with the
internal drive present at boot). Default cap is power state 2; override with
`POWER_STATE=1 sudo bash install.sh` if your drive is stable there.

## Probe your own drive first

Power states differ per drive. List them (`nvme id-ctrl /dev/nvme0 | grep ps`),
then from the recovery environment set each candidate state and run a sustained
direct write while watching `unsafe_shutdowns` in `nvme smart-log`:

    nvme set-feature /dev/nvme0 -f 0x02 --value=0x1
    dd if=/dev/zero of=/path/on/drive/test.bin bs=64M count=384 oflag=direct status=progress

If the counter increments or the drive vanishes (`blockdev --getsize64` reads
0), that state is too hot for the slot; step down and reboot to recover the
controller.

## Suspend and resume

Findings from suspend testing (2026-07-18, BIOS F7F0105, SteamOS 3.8.14, since
kept on 3.8.16):

- **Add `nvme.noacpi=1` to the kernel command line.** By default the kernel
  uses "simple suspend" for this drive: it stays powered through sleep and the
  controller is reset in place on wake, which reverts the power cap at the
  worst possible moment and can brown the drive out mid-resume (resume then
  hangs with nothing written to the journal). With `nvme.noacpi=1` the drive
  shuts down cleanly on suspend and cold-initialises on wake like a normal
  boot, which is the reliable path. Edit `GRUB_CMDLINE_LINUX_DEFAULT` in
  `/etc/default/grub` and run `update-grub`. `heal.sh` re-applies this if an
  update ever strips it.
- **The Steam Machine also has an unrelated intermittent s2idle resume hang.**
  Roughly one wake in three freezes: sometimes nothing comes back at all with
  the journal silent after `PM: suspend entry`, sometimes the pre-sleep frame
  is painted on screen with the clock frozen, input dead and no network. Across
  three instrumented captures the point of death moved (storage, then the
  Qualcomm Wi-Fi card re-initialising, then before anything could be logged),
  and two targeted fixes each changed the symptoms without curing them, which
  is why this reads as a platform firmware or kernel bug rather than any one
  driver. Reported to Valve.

Until Valve fixes it, the blunt workaround is to disable sleep entirely:

    sudo systemctl mask sleep.target suspend.target suspend-then-hibernate.target hibernate.target

Also set the idle sleep timer to "never" in Settings > Power, so Steam stops
attempting a sleep that will be refused. `heal.sh` keeps the masks in place on
both slots across updates. Reversing this is one `systemctl unmask` plus
removing the mask loop from `heal.sh`, and the sensible re-test is ten
suspend/wake cycles before trusting it again.

## HDMI-CEC: TV on, TV off

Worth knowing if you disable sleep on a Steam Machine plugged into a TV.

The machine can be **powered on from a full shutdown** by the TV over CEC: turn
the TV on and the console cold-boots by itself. This is a supported feature
(`WakeDevice` on the SteamOS manager's HDMI-CEC interface, writable if you want
it off), and it works from S5 because the embedded controller stays powered.
It also makes remote power-on trivial: anything that can turn the TV on, such
as a HomeKit or Alexa routine, boots the console as a side effect. No
Wake-on-LAN needed.

The reverse direction breaks once sleep is masked. Turning the TV off sends a
CEC standby, and SteamOS answers it by asking logind to **suspend**, which the
mask refuses:

    systemd-logind: Unit suspend.target is masked, refusing operation.
    cecd: ERROR Failed to standby: AccessDenied: Permission denied

So the TV goes dark and the console stays on indefinitely. The
`cec-standby-poweroff` service in this repo watches for exactly that refusal
and powers the machine off instead, restoring the console-like pairing: TV on,
machine on; TV off, machine off. It is self-limiting by design, since the
refusal only happens while sleep is masked, so it never fires again once sleep
is safe to re-enable.

Verified end to end on 2026-07-19: TV off produced

    cec-standby-poweroff: TV requested standby; powering off
    steam: Shutdown
    systemd: Reached target Shutdown

and the machine powered itself back on 79 seconds later when the TV was
switched on again.

Note it powers off rather than suspending, so a game left running is closed by
the shutdown. Steam Cloud syncs saves, but unsaved progress since the last
checkpoint is lost. If you would rather the TV did not power the console on at
all, `WakeDevice` on the HDMI-CEC interface is writable, and SteamOS exposes
the setting in its HDMI-CEC options.

## Caveats

- A **factory reset** wipes `/var` and `/home`, removing the fix and the healer.
  Re-run `install.sh` from the recovery environment.
- The heal log is at `/home/.nvme-power-cap/heal.log`.
- Fit a heatsink or thermal pad: bare, the E26 reached 85 C under load in this
  chassis (thresholds 87/89 C). With a low-profile copper finned heatsink and
  thermal pad it plateaus at 62 C under sustained gaming with zero throttle
  events. The brownout is electrical, not thermal, but the 23 C of headroom is
  well worth the fitting.
- With sleep masked, nothing turns the machine off on its own except the
  HDMI-CEC service above. Idle draw measured at roughly 10 W at the APU
  package (`amdgpu` `power1_average`, 20 samples), so probably 16 to 20 W at
  the wall once the drive, fans and supply losses are counted. The `intel-rapl`
  energy counter reports zero on this platform and cannot be used for energy
  accounting.
- **Unverified:** the drive's `unsafe_shutdowns` counter appeared to increment
  across one textbook-clean power off. The baseline reading was a day old, so
  this may be a stale comparison rather than a real effect. If it reproduces
  under a controlled read-shutdown-read test, it would suggest the platform
  does not send the drive a proper shutdown notification. Not yet tested.
- This is a workaround for a genuine hardware mismatch. The clean alternative is
  a lower-power PCIe Gen4 drive. Use at your own risk.

## Licence

MIT
