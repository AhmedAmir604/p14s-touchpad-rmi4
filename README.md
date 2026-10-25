# ThinkPad P14s Gen 2a RMI4 Touchpad Work

This repository contains an experimental, out-of-tree `i2c-piix4` module for
the Lenovo ThinkPad P14s Gen 2a. It is intended to enable the Synaptics
TM3471-030 touchpad’s native RMI4-over-SMBus path without periodic polling.

## Current Status

**2026-10-24: installed and persistent.** DKMS package `p14s-touchpad/0.1`
(see `dkms/README.md`) loads the three patched modules at boot; after
`update-initramfs -u` the pad comes up on RMI4/SMBus with no manual step,
community configuration (doze interval 6, NoSleep off), and
`dkms/tools/touchpad-check` prints OK. Evidence behind it: runs 3–7 and a
4.8 hour soak with 4 suspend cycles, all in `touchpad-rmi4-progress-report.md`.
Routine: run `touchpad-check` after kernel updates. Note that the harness's
preflight now sees the DKMS `i2c_piix4` as "already loaded" and will refuse
to run; for future experiments remove the DKMS package first or adapt the
harness.

**2026-10-23, later: experiment 1 passed on the transport; clickpad press
open.** Run 3 completed all scripted phases over 10 minutes on the native
RMI4/SMBus path: 15 ms frames, two-finger scroll, upper left/middle/right
buttons, TrackPoint on the pass-through, 4 collisions all recovered, zero
errors, stock restored. On that exp1 build (stock psmouse) the physical
clickpad press arrived on the TrackPoint input device via the F03
pass-through and the pad's F3A button function never interrupted. **With
the experiment 2 build (community psmouse doze patch) F3A fires and the
click arrives on the pad device as on PS/2, so libinput clickpad features
work** (runs 4–7). **Run 7 passed every phase including the automatic
30 s s2idle suspend/resume cycle on the community configuration** (doze
interval 6, NoSleep off): 19 of 20 taps, 15 ms frames before and after
resume, 22 collisions all recovered, zero errors. Run 5 had lost 17 of 20
taps on the same configuration for an unidentified reason; the local
`synaptics_rmi_nosleep=1` knob (run 6: 17 of 20) stays available as a
fallback if that recurs. Experiment 2 is run with
`pkexec ./run-asf-hardware-test.sh exp2` (append
`synaptics_rmi_nosleep=1` for the fallback). All README pass criteria are
now met on this build; what remains is daily-use soak and then DKMS. For
the soak use `pkexec ./run-asf-hardware-test.sh soak`: same load, same
automatic stock recovery, no scripted phases, ends on ENTER or Ctrl-C.
Earlier that
day, run 1 aborted on a harness check (parameter file not exposed by this
driver) and run 2 aborted on one isolated NAKed read, now counted rather
than fatal.

**2026-10-23 checkpoint: route changed, hardware run pending.** The
transport under test is now the community patch from
[orospakr/thinkpad-t14-amd-touchpad](https://github.com/orospakr/thinkpad-t14-amd-touchpad)
(`patches/0001-…SMB0001-platforms.patch`, version 0.2.3, Andrew Clunis,
GPL-2.0), applied unchanged to `i2c-piix4.c.orig` and built cleanly with
`make W=1` on `7.0.0-38-generic`. Our previous event-driven patch is kept
as `patches/probe3-ours-event-driven.diff` for reference only.

Why the switch: the pristine source both patches start from is
byte-identical, the community patch has run for weeks on three T14 Gen 2a
units (two with this pad's exact firmware id 3942087) and one T14 Gen 1,
and its field data answers the question probe 3 ended on. Bus collisions
are expected with the pad acting as a second master and are retried in a
bounded way: at most three retries after a 1 ms listen window, arbitration
loss retried always, a NAK retried only when the yield caught a Host Notify
from the same device. This replaces our "first collision is fatal" rule.
The harness now counts collisions and retries and treats only a transfer
still failing after the retries, ASF setup/teardown warnings, RMI failures
or resets, host timeouts, and IRQ storms as fatal.

No in-tree route exists. The kernel's `i2c-amd-asf-plat` matches only
ACPI `AMDI001A`, needs a memory resource `SMB0001` does not declare, and
has neither Host Notify nor read support; `acpi_platform.c` refuses a
platform device for `SMB0001` when it has `_CRS`. Two 2026 linux-i2c and
linux-input reports for the T14/L14 AMD got no fix.

Plan: experiment 1 loads the new `i2c-piix4` alone with stock `rmi_smbus`
and `psmouse` on the next fresh boot (one load, about ten minutes, no
suspend). Only after a pass does experiment 2 add the community resume-settle
and doze-interval patches; soak and suspend/resume follow; DKMS after that.
One persistent setting from earlier work is still present and is needed
for the experiment: `/etc/modprobe.d/synaptics-smbus.conf` sets
`psmouse synaptics_intertouch=1`.

### Previous status (2026-07-25, our own patch)

As of 2026-07-25, three guarded event-driven probes have run on
`7.0.0-27-generic`. Probe 3 verified that native RMI4 touch and F03/TrackPoint
can initialize with ASF fair arbitration active. After only 6.7 seconds of
the nominal hands-off phase, however, the controller reported `BusCollision`
on an F12 object-data block read amid very high Host Notify activity. Both
preflight samples had been idle and the snapshot confirmed `FairArbEn` plus
the 64 µs timer. This is most consistent with a remaining post-preflight
race, although the log did not capture the competing packet.

The harness aborted on the first fault and verified restored stock modules
and SynPS/2 touchpad/TrackPoint device nodes within seconds; the user then
confirmed normal stock input. No patched-path touch, scroll, clickpad, or
physical-button phase completed; those functions are not yet validated. IRQ
7 also ran at roughly 960 interrupts/s, with about 439 parent Host Notify
deliveries/s in the final sample, so idle traffic remains too high even apart
from the collision.

This is now a documented pause checkpoint. The tested source and module are
left unchanged for reproducibility; no retry experiment is implemented.
Boot `63d9306a-96b7-4a6d-8a0f-fcc9c3ebe014` is back on working stock drivers
but has consumed its one patched load. Reboot before any future experiment.
Nothing is installed persistently.

The earlier hrtimer polling prototype is retired. Even a clean 60 Hz run
caused `-EIO`/`-ENXIO` failures, RMI resets, missing physical-button events,
and eventual transport instability. The scripts named `gate1-setup.sh`
through `gate6-fix.sh` in `~/Downloads` are historical experiments and must
not be run.

`AGENTS.md` is deliberately preserved unchanged, but its instruction to begin
with `poll_hz=60` is stale. The current module has no polling parameter.
Follow this README and `touchpad-rmi4-progress-report.md` for hardware tests.

## Goal and Pass Criteria

The goal is a stable, activity-driven RMI4 transport with:

- responsive touch, two-finger scrolling, and gestures;
- a working clickpad press and all three upper physical buttons;
- zero SMBus transfer errors, failed RMI reads, resets, or IRQ storms;
- low idle IRQ activity and reproducible suspend/resume behavior.

TrackPoint movement is optional, but its upper left/middle/right buttons are
required. Pointer acceleration and gesture feel are tuned with libinput only
after the kernel transport passes.

## Why the Stock Path Is Slow

Linux currently leaves this pad on PS/2. Captured PS/2 frames had irregular
10–36 ms gaps and interleaved multi-finger updates. RMI4 communicates through
the AMD FCH auxiliary SMBus controller at `0xb20`, address `0x2c`, but the
stock PIIX4 driver does not implement the Host Notify mechanism required by
`rmi_smbus`.

The firmware describes an `SMB0001` ASF controller with a 32-byte I/O window
at `0xb20` and shared, level-low IRQ 7. A touch generates a real SMBus Host
Notify packet for host address `0x08`, carrying device address `0x2c`.

## Event-Driven Design

Note (2026-10-23): this section describes our previous patch, now kept as
`patches/probe3-ours-event-driven.diff`. The community patch under test
shares the event path below but differs in three ways: it is gated on the
`SMB0001` I/O base matching the aux adapter rather than on DMI,
`asf_host_notify` defaults to on, and it retries bus collisions as described
in Current Status instead of failing closed. Its full description is in the
patch header.

The patch is deliberately restricted to DMI product `21A0003QUS` and is
enabled only with `asf_host_notify=1`. It validates the exact ACPI I/O and IRQ
resources before changing hardware state.

The event path is:

1. The ASF slave receives the touchpad’s Host Notify packet.
2. IRQ 7’s hard handler clears the level-triggered source immediately.
3. Its explicit IRQ thread drains the ASF receive bank and forwards address
   `0x2c` through `i2c_handle_smbus_host_notify()`.
4. The stock I2C and RMI4 cores read the device and emit input events.

Auxiliary master transfers use the same real IRQ for completion. They acquire
the driver mutex and ASF host semaphore, then require two idle observations
20 µs apart before programming host registers. The checks cover HostBusy,
plus active and pending ASF receive state; raw DataBankSel is recorded for
diagnostics but its reserved bit is not used as a gate. Slave reception
remains active so hardware can arbitrate a touchpad-initiated Host Notify
against a host-initiated RMI read. ASF `FairArbEn` and
`DelayMasterTimer=0x20` provide a 64 µs fairness interval.

Safety measures include stale-completion draining before every command,
bounded timeout/abort handling, fail-closed behavior after a bus collision,
and a notification token bucket. Completed commands observe a 20 µs bus-free
guard before the next transfer. A failed RMI write is never replayed at this
transport layer because `DeviceError` does not prove whether the target
already acted on it. Any RMI transfer failure records the operation, its
preflight state, and Host/ASF/slave/bank/semaphore/fairness registers. A
sustained rate above 600 notifications/s with a 300-event burst allowance
kills only the ASF slave-notification path; host completion handling remains
available for orderly cleanup.

Probe 3 proved that these measures improve initialization and diagnostics but
are not yet a stable transport. The failure is consistent with the touchpad
beginning a new Host Notify immediately after the final idle sample, although
the competing packet was not captured. AMD fair arbitration only delays ASF
master packets; it does not reserve the bus.

## Repository Layout

- `i2c-piix4.c` — `i2c-piix4.c.orig` with the community patch applied
  (experiment 1 build, root `Makefile`).
- `exp2/` — Kbuild tree for experiment 2: Ubuntu 7.0.0-38 sources for
  `i2c-piix4`, `rmi_smbus`, and `psmouse` with community patches 0001–0003
  applied. Build with `make -C /lib/modules/$(uname -r)/build M=$PWD/exp2 modules`.
- `dkms/` — the DKMS source tree for persistence (Ubuntu sources, community
  patches 0001–0003, local 0006, `tools/touchpad-check`). See `dkms/README.md`
  for install, fallback knob, kernel-update and removal steps.
- `patches/0001-…SMB0001-platforms.patch` — the community piix4 patch.
- `patches/0002-…SMBus-resume.patch`, `patches/0003-…affected-ThinkPads.patch`
  — the community `rmi_smbus` resume-settle and `psmouse` doze patches.
- `patches/0006-local-psmouse-rmi-power-management-knobs.diff` — our local
  addition on top of 0003: psmouse parameters `synaptics_rmi_nosleep` and
  `synaptics_rmi_doze_interval` plus a log line showing what was passed.
  Pass them as the harness's second argument:
  `pkexec ./run-asf-hardware-test.sh exp2 synaptics_rmi_nosleep=1`.
- `patches/probe3-ours-event-driven.diff` — our previous patch, reference only.
- `i2c-piix4.c.orig` — untouched upstream comparison baseline.
- `i2c-piix4.h` — matching kernel header.
- `Makefile` — external Kbuild entry point.
- `run-asf-hardware-test.sh` — guarded one-load test, logging, and automatic
  stock-module recovery.
- `touchpad-rmi4-progress-report.md` — evidence, failed experiments, and
  current validation state.
- `AGENTS.md` — contributor instructions.

Files such as `*.ko`, `*.o`, `*.mod*`, `Module.symvers`, `modules.order`, and
hidden `*.cmd` files are generated.

## Build and Static Checks

```bash
make clean
make W=1
modinfo ./i2c-piix4.ko
diff -u i2c-piix4.c.orig i2c-piix4.c
```

`vermagic` must match `uname -r`. The experimental module should expose only
the standard `force`/`force_addr` parameters plus `asf_host_notify`; polling
parameters indicate that an obsolete artifact was built.

## Hardware-Test Rules

- Start from a fresh boot and make only one patched-module load attempt.
- Use `run-asf-hardware-test.sh`; do not substitute a manual `insmod`, because
  its monitoring and immediate stock recovery are safety requirements.
- Confirm IRQ 7 has no existing consumer before changing its route.
- Capture the boot ID, module hash, complete kernel log, IRQ counters, and
  input-device list before and after the test.
- Never use `i2cdetect`, `i2cget`, or another raw probe on address `0x2c`
  while RMI owns the touchpad.
- Abort on a transfer still failing after the driver's bounded retries, any
  ASF setup/teardown warning, RMI read failure/reset, timeout, or IRQ storm.
  Bus collisions and retries are expected and are counted, not fatal; the
  harness enables dynamic debug for `i2c_piix4` so they appear in the log.
- Test touch, scroll, clickpad press, and upper L/M/R buttons separately.
- Do not install the module in initramfs, DKMS, or modprobe configuration
  until soak and suspend/resume tests pass on later boots.

The controlled run removes `psmouse`, replaces the stock PIIX4 module, loads
the patch with `asf_host_notify=1`, and reloads `psmouse` with
`synaptics_intertouch=1`. On failure it takes a quick snapshot, restores stock
immediately while live kernel logging remains active, and only then performs
the slower full snapshot.

Superseded (2026-10-23): the planned `DelayMasterTimer=0xff` experiment on
our own patch is dropped in favour of the community patch; see Current
Status. The retry concern recorded here (a replayed write after
`DeviceError`) does not apply to arbitration loss, where the host never got
the bus, and the community patch retries a NAK only when the pad was
provably mid-notify. The next experiment is one guarded load of the current
build on a fresh boot.

Same-boot stock recovery restores the PS/2 input path:

```bash
sudo modprobe -r psmouse
sudo modprobe -r i2c_piix4
sudo modprobe i2c_piix4
sudo modprobe psmouse
```

On this x86 legacy IRQ, unregistering GSI 7 does not restore its original
edge/high IO-APIC route. Therefore a reboot is the definitive cleanup after
any patched load, even when stock PS/2 works again.

## Historical Correction

The Gate 3 retry wrapper and Gate 6 semaphore timing changes affected
`piix4_access_sb800()`, which serves the multiplexed main controller. The
touchpad’s auxiliary adapter calls the plain `piix4_access()` path. Those
knobs therefore never protected auxiliary touchpad transfers, and the old
`-EBUSY` interpretation as proof of EC/IMC contention was unsupported.

Primary references are the
[AMD Family 16h Models 30h–3Fh BKDG](https://www.amd.com/content/dam/amd/en/documents/archived-tech-docs/programmer-references/52740_16h_Models_30h-3Fh_BKDG.pdf),
the [AMD SP5100 register guide](https://www.amd.com/content/dam/amd/en/documents/archived-tech-docs/programmer-references/44414.pdf),
and Miroslav Bendík’s
[P14s ASF investigation](https://www.spinics.net/lists/linux-input/msg75885.html).
