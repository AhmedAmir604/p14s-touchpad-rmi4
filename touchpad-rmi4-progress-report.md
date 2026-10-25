# ThinkPad P14s Gen 2a Touchpad: RMI4 Progress Report

**Hardware:** Lenovo `21A0003QUS` (ThinkPad P14s Gen 2a), Synaptics
TM3471-030 at SMBus address `0x2c`  
**Kernel:** Ubuntu `7.0.0-38-generic` (stable 7.0.14; probes 1–3 ran on `7.0.0-27-generic`)  
**Updated:** 2026-10-23  
**Current state:** checkpoint, hardware run pending on the next fresh boot.
See "2026-10-23 Checkpoint" below. The July state that follows is kept as
history.

**State as of 2026-07-25:** paused after three event-driven probes. Probe 3 completed
native touchpad and F03/TrackPoint initialization with fair arbitration
verified active, but an F12 object-data read collided after only 6.7 seconds
of the nominal hands-off phase. The harness verified restored stock modules
and PS/2 device nodes; the user subsequently confirmed normal stock input.
Touch, scroll, clickpad, and physical-button phases on the patched path remain
unvalidated.
Boot `63d9306a-96b7-4a6d-8a0f-fcc9c3ebe014` has consumed its one patched
load; reboot before any future experiment.

## Objective

Use the touchpad’s native RMI4-over-SMBus transport with stable touch and
scroll timing, a working clickpad press, and all three upper physical buttons.
TrackPoint motion is not required, although its button path may still depend
on RMI function F03. A pass requires zero transport errors, resets, timeouts,
or runaway IRQ activity, plus a low and stable notification rate while idle.

## Hardware Path

The AMD FCH has a main SMBus controller at `0xb00` and an auxiliary ASF
controller at `0xb20`. ACPI device `SMB0001` describes the auxiliary block as:

- I/O: Decode16, base `0xb20`, length `0x20`;
- IRQ: GSI 7, level-triggered, active-low, shared.

The touchpad sends SMBus Host Notify to host address `0x08`; the receive bank
contains bytes `0x10` and `0x58` (`0x2c << 1`). The stock driver can perform
auxiliary SMBus commands but does not expose Host Notify, so intertouch falls
back to PS/2.

## Evidence From the Retired Polling Prototype

The first patch advertised `I2C_FUNC_SMBUS_HOST_NOTIFY`. That allowed stock
`psmouse`, `rmi_smbus`, and RMI core drivers to identify TM3471-030 over
SMBus, proving that the address and basic command transport are real.

An hrtimer then called `i2c_handle_smbus_host_notify()` periodically:

- RMI4 delivered both fingers in each frame instead of PS/2’s interleaving.
- Recorded frame gaps became a steady ~11.5 ms rather than PS/2’s irregular
  10–36 ms.
- At 200 Hz, repeated `-5`/`-6` errors broke F03/F12 traffic, stopped physical
  buttons, and eventually wedged the input path.

The final valid polling experiment began from a clean boot, delayed polling
for 10 seconds, and used 60 Hz. RMI4 probed cleanly before the timer started.
Within about one second of timer activation, `-EIO` and `-ENXIO` IRQ-read
failures began. A controlled 25-second input capture emitted touch events but
no `BTN_LEFT`, `BTN_MIDDLE`, or `BTN_RIGHT`; parent RMI IRQs advanced while
F3A and F03 nested counters remained at zero. Totals included 200 `-5`
mentions, 141 `-6` mentions, 63 F12 object-read failures, and nine failed
transaction resets.

**Decision:** blind polling is disproven and permanently retired. Do not run
the historical `gate*.sh` scripts in `~/Downloads`.

## Correction to Earlier Diagnosis

The old Gate 3 retry loop and Gate 6 `sem_wait_us` change wrapped
`piix4_access_sb800()`. That function serves the multiplexed main controller.
The auxiliary touchpad adapter uses plain `piix4_access()`, so those retry and
semaphore settings never affected touchpad transfers. Consequently:

- Gate 7 did not validate auxiliary `-EBUSY` retry behavior;
- the apparent parameter response was contaminated by repeated reloads;
- auxiliary `-EBUSY` was not evidence that the EC/IMC semaphore caused the
  failures.

This invalidates the old polling-rate ladder and its tuning recommendations.

## Current Event-Driven Implementation

`i2c-piix4.c` now implements the platform’s actual ASF event path instead of
an hrtimer. Activation requires all of the following:

1. explicit read-only module parameter `asf_host_notify=1`;
2. exact Lenovo DMI vendor, product, and product-version match;
3. AMD KERNCZ/FCH SMBus PCI ID;
4. exact 32-byte `SMB0001` I/O resource and level-low shared IRQ.

Only the matching auxiliary adapter advertises Host Notify. The standard main
adapters retain their upstream algorithms.

The driver registers GSI 7 as level-low, requests a shared hard handler plus
an explicit IRQ thread, and enables ASF listen mode only after the I2C Host
Notify domain exists. The hard handler clears HostStatus and SlaveIntr
level sources. The thread drains both receive banks in FIFO order, accepts
only the expected `0x08`/`0x2c` packet, and forwards it to the I2C core.

Auxiliary master commands are serialized under a mutex and the ASF host
semaphore. Completion is driven by the real HostStatus interrupt. The current
revision leaves slave reception active during ordinary commands, enables ASF
fair arbitration, and performs a bounded idle preflight before programming a
master transaction. Timeout recovery issues KillHost, clears and synchronizes
late interrupts, and leaves the slave killed if the host cannot be recovered.

Additional fail-safes:

- stale HostStatus interrupts are cleared, synchronized, and verified before
  every new transfer;
- an ASF bus collision disables further auxiliary traffic;
- KillSlave remains available for fail-closed recovery and teardown, but is
  not pulsed around each normal transfer;
- receive draining is bounded to 32 rounds;
- a token bucket permits 600 notifications/s plus a 300-event burst, then
  kills only the slave-notification path on a sustained storm;
- teardown disables and synchronizes notifications before deleting the I2C
  adapter, then frees the IRQ and restores saved ASF registers.

## First Event-Driven Hardware Probe

The guarded run
`test-logs/20260725T160635Z-b6584c98/` performed the first real patched load.
The event path and master-completion IRQ both worked:

- IRQ 7 registered level-low and Host Notify enabled.
- `rmi4_smbus` registered address `0x2c`.
- RMI F01 identified TM3471-030, firmware `3942087`.
- The RMI touchpad, F03 pass-through port, and Elan TrackPoint input device
  were created.
- Before recovery, IRQ 7 counted 970 physical interrupts, the RMI Host Notify
  parent counted 378, and nested F03 counted 16.

At the final TrackPoint activation step, `rmi_f03_pt_write()` returned
`-ENXIO`, followed by `Failed to enable mouse`. No ASF timeout, collision,
failed reset, stuck-host, drain-limit, or rate-limit error preceded it. The
harness aborted immediately and verified `stock-restored`; touch and physical
buttons returned through the stock PS/2 devices.

Kernel source tracing identifies the failed high-level operation as the PS/2
`ENABLE` command (`0xF4`). Many earlier F03 probe commands succeeded. The old
log cannot distinguish whether the underlying failure was the RMI SMBus
mapping-table write preceding that command or its one-byte payload. RMI F03
does not retry a transport write failure, and the I2C core retries only
`-EAGAIN`, not this ASF `DeviceError/-ENXIO`. The result is consistent with a
transient bus-handoff/timing problem, but does not prove a target NACK or
arbitration loss.

## Second Event-Driven Hardware Probe

The guarded run
`test-logs/20260725T163248Z-f5454350/` tested the 20 µs post-completion
bus-free guard and expanded `DeviceError` snapshot. Its monotonic timeline
was:

- `80.735021`: patched module loaded.
- `80.737013`–`80.741314`: exact ASF `0xb20`/GSI 7 resources validated,
  IRQ 7 prepared level-low, and Host Notify enabled.
- `81.699021`–`81.896013`: `rmi4_smbus` registered, F01 identified the pad,
  and the native RMI touch input appeared.
- `81.907021`–`82.013020`: F03 port, TrackPoint identification, and
  TrackPoint input creation all succeeded. Unlike the first probe, the F03
  PS/2 `ENABLE` (`0xF4`) initialization completed.
- `82.528046`: the first transport error was
  `rw=R cmd=07 size=5 ... host=06 ... bank=01`. The paired RMI message was
  `Failed to read irqs, code=-6`.
- `82.638048`: a distinct ASF bus collision occurred 110 ms later, followed
  by an F12 object-read `-5`.

Here `cmd=07` is dynamic SMBus mapping slot 7, not RMI register `0x07`, and
`size=5` is the kernel’s `I2C_SMBUS_BLOCK_DATA` enum value, not a five-byte
payload. Source correlation identifies the failed operation as the one-byte
F01 `data_base + 1` interrupt-status read performed while processing a real
Host Notify. Host status `0x06` means completion interrupt plus
`DeviceError`; it contains no collision bit. Therefore the later collision
is a separate event, not another label for the first failure.

IRQ 7 reached 776 physical interrupts. Samples advanced by 72 and then about
702 interrupts/s; the RMI parent reached 238, nested F12 reached 18, and
nested F03 reached 16. These rates remained below the 5,000/s safety cutoff,
so there was no IRQ storm. The harness aborted before physical touch/button
phases, automatically restored the stock modules, and verified
`stock-restored`.

An `iwlwifi` firmware assertion appeared several seconds after stock recovery.
It is recorded as an unrelated observation; there is no demonstrated link to
the ASF touchpad experiment.

## Fair-Arbitration Revision

The second probe shows that a post-completion delay alone does not prevent
host/slave overlap. The touchpad is itself an SMBus master while sending Host
Notify. Pulsing local KillSlave before every outbound command can discard
notification state, but cannot stop an already-started touchpad transmission.

The fair-arbitration revision therefore:

1. removes per-transfer KillSlave while retaining it for fail-closed recovery
   and teardown;
2. sets SlaveEn `FairArbEn` and DelayMasterTimer `0x20` (64 µs), saving,
   verifying, and restoring the original values;
3. requires two quiet samples 20 µs apart before touching host
   address/command/data registers. The bounded check observes HostBusy, ASF
   Status bit 7 (SlaveBusy), the empirically required Status bit 6
   (SlaveIntr pending), and records raw DataBankSel for diagnostics without
   treating its reserved bit 6 as a gate;
4. keeps the existing post-completion 20 µs delay, treats any collision as
   fatal, and performs no automatic read or write retry;
5. records expanded snapshots for every RMI transfer failure, including
   preflight state, SlaveEn, arbitration timer, host control/status, ASF
   status, bank, slave status, and semaphore.

The test harness also restores stock immediately after a fault while the live
logger is still running. Slow full snapshots now occur after recovery and
kernel-log collection is bounded, preventing diagnostics from delaying
touchpad restoration or omitting teardown messages. This revision is built
and statically checked. Probe 3 tested it and showed that 64 µs fairness plus
software idle qualification is not sufficient.

## Third Event-Driven Hardware Probe

The guarded run
`test-logs/20260725T173705Z-63d9306a/` tested the reviewed fair-arbitration
build. Its exact sequence was:

- `2064.437021`–`2064.443485`: patched module loaded, exact ASF resources
  validated, IRQ 7 prepared level-low, and Host Notify enabled with 64 µs
  fair arbitration.
- `2065.388045`–`2065.738016`: RMI SMBus registered, F01 identified
  TM3471-030 firmware `3942087`, and both the native touchpad and F03
  TrackPoint input devices were created.
- `2066.51`–`2069.56`: the monitored three-second probe-settle phase
  completed.
- `2069.59`: the nominal hands-off phase began.
- `2076.258029`: the first transport fault was an ASF bus collision.
  The paired transaction snapshot was
  `err=-5 rw=R cmd=05 size=5 pre=00/00/80 idle=00/00/80 host=0a`
  `live=00 control=14 asf=00 slave=00 bank=80 sem=01 enable=c3 timer=20`.
- `2076.258995`: F12 reported `Failed to read object data. Code: -5`.

`cmd=05` is dynamic SMB2 mapping slot 5, not RMI address `0x05`, and
`size=5` is the `I2C_SMBUS_BLOCK_DATA` enum. The paired F12 message proves
that this was an F12 object-data block read; the log cannot reconstruct the
slot’s exact underlying RMI address or length. Host shadow `0x0a` is
completion plus `BusCollision`. Both preflight samples were quiet, the live
host status had cleared, and `enable=c3`/`timer=20` prove that continuous
slave listen, `FairArbEn`, and the 64 µs timer were active.

This disproves the 64 µs fair-arbitration revision as a complete fix. The
failure is most consistent with a touchpad Host Notify beginning after
software’s final idle sample, but the trace did not capture the competing
packet. AMD’s fairness timer delays ASF master packets rather than reserving
the bus.

### IRQ and Input Evidence

After startup, IRQ 7 advanced at approximately 959–962 interrupts/s. Between
the quick snapshots at uptimes `2069.57` and `2076.73`:

- physical IRQ 7 rose from 3,894 to 10,194: +6,300 in 7.16 seconds,
  approximately 880/s over that interval;
- parent `rmi4_smbus` notifications rose from 1,842 to 4,984: +3,142,
  approximately 439/s;
- nested F12 rose from 0 to 5;
- nested F03 remained at 17.

This was not an explosive IRQ storm under the 5,000/s abort threshold, but
it is far too noisy for the eventual quiet-idle goal. `evtest-event7.log`
contains four contact frames around collision/teardown, after an explicitly
hands-off phase. They may be stale or ghost data and are not accepted as a
successful touch test. Event 8 advertised `BTN_LEFT`, `BTN_MIDDLE`, and
`BTN_RIGHT`, but no physical button was exercised. No functional phase
completed.

### Recovery Evidence

The post-collision teardown write failure at `2076.772` was expected after
the auxiliary path had failed closed; it was not the initiating fault. Stock
PIIX4 reload began at `2077.070`, the SynPS/2 touchpad returned at
`2078.197`, and the stock TrackPoint returned at `2078.917`.
`recovery-status.txt` says `stock-restored`; the after-recovery module and
input snapshots verify stock `i2c_piix4`, `psmouse`, SynPS/2 event 7, and
TPPS/2 event 8. That automated evidence proves device presence, not button
events; the user separately confirmed normal stock input afterward. IRQ 7
currently has no consumer.

Unrelated boot-time Renesas firmware fallback, Bluetooth `-16`, AMDGPU DMCUB
errors, and AppArmor denials predate the probe and have no demonstrated link
to the touchpad collision.

## Static Validation Completed

- `i2c-piix4.c.orig` remains byte-for-byte unchanged from the extracted
  upstream source.
- `make W=1` completes without code warnings.
- The rebuilt module’s `vermagic` matches `7.0.0-27-generic`.
- `modinfo` exposes `asf_host_notify` and no polling/retry parameters.
- Checkpatch reports no code findings; only commit-message and
  `Signed-off-by` metadata are absent because this is not yet a submission.
- Independent reviews covered ACPI GSI mapping, level-low IRQ behavior,
  explicit hard/thread separation, I2C Host Notify domain lifetime, timeout
  races, adapter teardown, and the steady-rate IRQ-storm case.

The source SHA-256 used in the second hardware probe was
`1c86171ebe9aea78c77028a8a60ab53ed128451ba286bae7e62a2a07bc80bcf1`;
its module SHA-256 was
`c261265e6e933b88f0a474214c644b795c2867f69093521a51807bbdce16f52a`.
The reviewed fair-arbitration source SHA-256 is
`28695503eab9af6f410bf26232d2b44138f865330b5a91b6b11dff05ae81f2d4`;
the rebuilt module SHA-256 is
`5251c0f59ad8fcc9d3dd622b050015f1806ce011172835f1f84d3f8835e41e0c`;
and the guarded harness SHA-256 is
`56e0b3622fc574dfb1a8bc5647e94b41a2f18dc0016ba7ece34c405ba641beb5`.
Static checks reduced risk, but probe 3 demonstrated that this revision is
not stable on hardware.

## Controlled Live-Test Protocol

Any future test must follow a reboot and be the only patched load on that new
boot. Do not rerun in boot `63d9306a-96b7-4a6d-8a0f-fcc9c3ebe014`;
unregistering GSI 7 does not restore the original route. Do not rerun the
current 64 µs build unchanged: probe 3 already established its result.

Before loading:

- record the boot ID, kernel, source/module hashes, module parameters, full
  kernel log, `/proc/interrupts`, and `/proc/bus/input/devices`;
- confirm stock `i2c_piix4` and `psmouse` are active and all physical buttons
  work;
- confirm IRQ 7 has no existing action.

The guarded `run-asf-hardware-test.sh` harness will remove `psmouse`, replace
the stock PIIX4 module, insert the local module with `asf_host_notify=1`, and
reload `psmouse` with `synaptics_intertouch=1`. Do not replace it with manual
module commands. It monitors logs and IRQ counts continuously, with automatic
stock-module recovery on the first:

- `-5`, `-6`, `-16`, timeout, failed reset, or bus collision;
- RMI IRQ/object read failure;
- notification-rate or drain shutdown;
- runaway IRQ 7 rate.

Any `DeviceError/-ENXIO` immediately stops the functional phases and triggers
automatic stock-module recovery.

Validation stages are:

1. 30 seconds hands-off: successful RMI probe, quiet idle IRQ behavior.
2. Touch and pointer motion.
3. Two-finger scrolling.
4. Clickpad press.
5. Upper physical left, middle, and right buttons.
6. Correlate parent, F12/F3A/F03, and input event counters.

No `i2cdetect`, `i2cget`, or raw access to bound address `0x2c` is permitted.

After the capture, stock modules must be restored. This returns the PS/2
input path, but `acpi_unregister_gsi(7)` does not restore the legacy
IO-APIC’s original edge/high route on this kernel. A reboot is therefore the
definitive cleanup and the boundary before any later experiment.

## Remaining Unknowns

- Whether the documented maximum fairness timer, `0xff` or 510 µs, can avoid
  the observed collision window during F01/F12 processing. The tested
  `0x20`/64 µs value cannot.
- Why the RMI parent notification counter advances roughly 439 times/s while
  nominally idle, and whether safe notification coalescing can reduce that
  traffic.
- Whether any collision can be recovered without losing an RMI event.
  F01 interrupt-status reads are read-to-clear, so replaying reads is not
  automatically correctness-preserving.
- Whether upper buttons arrive through F03, F3A, or both on this firmware.
- Long-run behavior, power-state transitions, suspend/resume, and final
  libinput tuning. None should be attempted before transport stability.

## Unimplemented Next Options

No next transport change has been made at this checkpoint.

The smallest isolated experiment is to change only
`PIIX4_ASF_FAIR_ARB_TIMER` from `0x20` to `0xff`, increasing AMD’s documented
delay from 64 µs to the 510 µs maximum. Keep the current 20 µs preflight,
continuous listen, fatal collision handling, and no retries. A fresh-boot
hands-off run would then answer whether timer tuning has any remaining value.
If it collides again, timer tuning is effectively disproven.

This is one behavioral-variable experiment, but the hardcoded successful-load
diagnostic must also change from `64 us` to `510 us` so the new log remains
truthful. Do not combine it with another transport change.

Do not add generic I2C retries. Linux retries only `-EAGAIN`, this adapter’s
`retries` field is currently zero, and the PIIX4 layer sees only dynamic
mapping slots. Writes may already have side effects. Reads are safer but not
universally idempotent: F01 interrupt status is explicitly read to clear
IRQs. A later recovery experiment, if justified, should be an ASF-local
block-read-only loop with exactly two total attempts and explicit bus
requalification; any write collision, second read collision, persistent
busy/status, timeout, or other error must remain fail-closed. That option
accepts a possible lost-frame tradeoff and is not implemented.

The high unsolicited notification rate is likely the larger architectural
problem. Burst coalescing may eventually be needed, but it must be designed
and tested separately from timer or retry changes.

## 2026-10-23 Checkpoint

### What changed

- The kernel moved to `7.0.0-38-generic` (stable 7.0.14); `7.0.0-27` is no
  longer installed, so the probe 3 module cannot load. Secure Boot is off.
  `dkms` is not installed.
- Research confirmed there is still no in-tree route: `i2c-amd-asf-plat`
  matches only `AMDI001A`, requires a MEM resource `SMB0001` lacks, and
  implements neither Host Notify nor reads; `acpi_platform.c` refuses a
  platform device for `SMB0001` with `_CRS` (Hans de Goede, 2018, HP
  regression; relaxed in 2023 only for resource-less nodes). 2026 reports on
  linux-i2c (T14 Gen 2, LEN2073) and linux-input (L14 AMD) got no fix.
- The transport under test is now the community patch
  `patches/0001-…SMB0001-platforms.patch` from
  orospakr/thinkpad-t14-amd-touchpad 0.2.3 (commit d58868d, 2026-10-18).
  Its pristine `i2c-piix4.c` matches our `i2c-piix4.c.orig` byte for byte.
  It is tested on three T14 Gen 2a units (two with this pad's firmware id
  3942087, one with this BIOS 1.34) and one T14 Gen 1: 15 ms reports,
  gestures intact, TrackPoint on the pass-through, S3 and s2idle resume.
- Our own patch is preserved as `patches/probe3-ours-event-driven.diff`.
- Retry policy accepted: at most 3 retries after a 1 ms listen window;
  `-EAGAIN` (arbitration lost, host never had the bus) retried always;
  `-ENXIO` retried only if the yield drained a Host Notify from the same
  address. The July concern about replaying a write after `DeviceError`
  therefore does not apply to the arbitration case.
- Community findings relevant to later phases: dropped taps and phantom
  pinches were the pad's F01 doze interval (fixed in psmouse, patch 0003),
  not collisions; a resume jump needs a 300 ms settle in `rmi_smbus`
  (patch 0002). Both are deferred to experiment 2.
- Harness: collisions and retries (`Bus collision!`, `lost the bus`,
  `receive bank stuck full`) are counted via dynamic debug, logged in
  `collisions-and-retries.log` and as a fifth column of `irq7-rate.tsv`.
  Fatal: `still failing` after retries, any `ASF:` warning, RMI failure or
  reset, host timeout, IRQ 7 over 5000/s. Idle gate is 60 s and a 5 minute
  free-use soak follows the button tests. The IRQ action name is
  `piix4-asf`; the probe message is `SMBus Host Notify enabled via ASF`.
- Build: `make W=1` is clean for the patched file on `7.0.0-38-generic`;
  `vermagic` matches; parameters are `force`, `force_addr`,
  `asf_host_notify`. `checkpatch --strict` on the patch reports style only.
- `/etc/modprobe.d/synaptics-smbus.conf` (`psmouse synaptics_intertouch=1`)
  is a persistent leftover from earlier work, kept because the experiment
  needs it. The kernel's own `psmouse` does not list `LEN2073`.
- `AGENTS.md` no longer recommends `poll_hz=60`.

### Checkpoint hashes

- source `75e371edf4ad368c40d867c3f9cd2628751e191c95651ca4786b22015accf9b4`
- module `32a11f6c40968073135f0fda214762f349e66f612a4c1a2b0fc59db77e3f07e0`
- harness `5e930af52082b6c3799da81ae74e814a2c699f7e748ab94828173421a6c80af9`
  (after runs 1 and 2: srcversion detection, narrowed dynamic debug, and
  `Failed to read irqs, code=-6` counted, fatal only above 3 per minute)
- header `2e41c2f6f385f45e20a5f51f6d65fe16785b9c65fa4a312c1e5354366ccf8788`
- Makefile `89984ac428b576f13b7328c4f4d67aaec7b3a1235579a4fe8a846bfa5adfc67c`
- community patch `36981225fe2d453068979e6b8a87a0d706ad8601495109d89cb391a97e4f4333`
- our reference diff `541cb8196186436a1802863126c21e0e9934b7ad7d543267af1275f7769cb339`
- `i2c-piix4.c.orig` `4090404533b3a372acd1809e25d2c525edf00295e5e4c319bb096a33bfadbbba`

### Run 1 of the community patch, 2026-10-23 (harness bug, driver fine)

Boot `d6033a3a`, kernel `7.0.0-38-generic`, logs in
`test-logs/20261023T053834Z-d6033a3a/`. The driver loaded and reported:

```
piix4_smbus 0000:00:14.0: ASF SMBus slave (SMB0001) at 0x0b20, GSI IRQ 7 (level/low)
piix4_smbus 0000:00:14.0: SMBus Host Notify enabled via ASF (IRQ 7)
```

`/proc/interrupts` showed IRQ 7 as `IR-IO-APIC 7-fasteoi piix4-asf` with 2
interrupts and no errors of any kind. The harness then aborted on its own
check: this driver declares `module_param(asf_host_notify, bool, 0)`, so no
sysfs parameter file exists. Stock recovery completed and was verified
(SynPS/2 touchpad and TrackPoint present). psmouse was never reloaded, so
no RMI4 attach was attempted; nothing about touch behaviour is learned.

Harness fix: the patched module is now identified by `srcversion`
(`/sys/module/i2c_piix4/srcversion` versus `modinfo -F srcversion`) in the
preflight, post-insmod, health, and recovery checks. The boot has consumed
its one patched load; reboot before run 2.

### Run 2 of the community patch, 2026-10-23: transport works, one NAKed read

Boot `2356d6a7`, logs in `test-logs/20261023T054210Z-2356d6a7/`. First time
this machine has run the touchpad natively on RMI4/SMBus.

- Load at 55.5 s; `rmi4_smbus 4-002c` registered; `Synaptics TM3471-030`
  input at 56.8 s; F03 pass-through and `TPPS/2 Elan TrackPoint` at 56.9 s.
- Pad used (against instructions) from 65 s through the 60 s idle gate and
  the following wait: 63,270 evtest events over about 173 s, 7,422 Host
  Notifies, frames every 14–15 ms, up to four fingers tracked, one clickpad
  `BTN_LEFT`, and on the TrackPoint device left ×5, middle ×1, right ×1.
  No `SYN_DROPPED`.
- IRQ 7 total 36,757 = 29,341 host transactions + 7,422 notifies: this
  driver raises IRQ 7 once per host transaction (acked in the hard handler),
  so the "high" IRQ 7 rate of probes 1–3 was the normal cost of four reads
  per frame, not a storm.
- Two bus collisions (79.85 s and 222.50 s), both `lost the bus (-11)`,
  both recovered on retry 1; zero `still failing`.
- At 237.888 s, 0.4 ms after a notify, the F01 interrupt-status read got
  `Error: no response!` (NAK, `-ENXIO`); the driver's yield caught no notify
  from the pad, so it did not retry, and `rmi4_physical rmi4-00: Failed to
  read irqs, code=-6` was logged. The next notify came 2.4 ms later and
  every subsequent read succeeded; the pad's next frame arrived normally.
  One frame was lost, nothing reset. The harness treated it as fatal and
  restored stock (verified).
- Full-module dynamic debug logged every transaction twice (6.4 MB log,
  about 480 printk/s under touch); the harness now enables only the `ASF:`
  and `Bus collision` lines.

This is the event orospakr counts as the metric that matters ("Failed to
read…", 9 in a week on his unit before the doze patch, 0 after in captures).

### Run 3 of the community patch, 2026-10-23: full scripted pass, clickpad gap

Boot `716b5755`, logs in `test-logs/20261023T055505Z-716b5755/`. All phases
completed (621 s on the patched path), zero fatal events, stock restored and
verified. Harness as hashed above.

| Phase | Pad frames | Touches | Result |
|---|---|---|---|
| idle-hands-off 60 s | 0 | 0 | IRQ 7 at 0/s, nothing on the bus |
| one-finger-motion 15 s | 759 | 5 | 15.0 ms mean interval, 13.5–44 ms, 3 over 30 ms |
| two-finger-scroll 15 s | 751 | 18 | 15.4 ms mean, 17 two-finger frames |
| clickpad-press 15 s | 319 | 5 | pressure up to 95, **no BTN_LEFT** (see below) |
| upper-left / middle / right | 0 | 0 | TrackPoint device: L ×5, M ×5, R ×6 |
| free-use-soak 300 s | 11,630 | 258 | 15.9 ms mean, 204 of 11,361 intervals over 30 ms; TrackPoint L ×20, R ×2 |

Totals: 17,439 Host Notifies, 87,181 IRQ 7, 4 collisions (360.6, 404.6,
595.2, 595.3 s) all recovered on retry 1, 0 `still failing`, 0 `code=-6`,
0 `SYN_DROPPED`. Peak IRQ 7 about 350/s under continuous touch.

**Open gap: the physical clickpad press produces no event over RMI4.** The
pad device advertises `BTN_LEFT` (registered by `rmi_f3a`, which found a
GPIO that exists and is an input), but no `BTN_LEFT` was emitted in run 2 or
run 3, and the `rmi4-00.fn3a` interrupt count stayed at 0 for the whole run
while F12 took 17,319. The firmware never raised the F3A interrupt on a
press. The community project has the same shape: its probe logs show
`fn3a` at 0 interrupts and none of its evtest captures contain a `BTN_LEFT`
press; its "clicks" are libinput tap-to-click. The community F01 dump shows
the F3A interrupt bit enabled (`c8` = F12, F3A, F03), so it is not a
missing enable in F01. Whether the user felt a mechanical click during the
phase is not yet confirmed. Candidate next step: a small debug build of
`rmi_f3a` (or `rmi_core debug_flags`) that logs the F3A data register on
every F12 frame, to see whether the GPIO state changes on a press at all.
Tap-to-click via libinput is unaffected.

**Resolved the same day:** the user reports the physical clickpad press
worked throughout. The log agrees once the right device is read. All 20
`BTN_LEFT` presses on the TrackPoint device during free use (357–462 s)
occurred with a finger on the pad at pressure 56–69, whereas the five in
the upper-left phase (243–253 s) had no finger on the pad. So on this
machine, over RMI4, the clickpad switch is delivered as `BTN_LEFT` on
`TPPS/2 Elan TrackPoint` through the F03 pass-through, not on the pad's own
input device, and F3A plays no part. The clickpad phase's five presses at
pressure up to 95 registered no click on either device; most likely the
switch was not actuated there. Consequence: a plain left click works
everywhere; libinput clickpad semantics that need the button on the
touchpad device (two-finger press for right click, software button zones)
will not, and tap-to-click is unaffected. On PS/2 the same switch is
reported on the pad device. This is a known limitation to document, not a
transport fault; routing it to the pad device would be input-layer work.

Verdict: experiment 1 passes. Transport, touch, scroll, three upper
buttons, TrackPoint, and the physical left click all work; the click's
device placement is the one documented deviation.

### Experiment 2 checkpoint, 2026-10-23: three modules built, run pending

- `exp2/` is a Kbuild tree holding the exact Ubuntu `7.0.0-38.38` sources
  (from the installed `linux-source-7.0.0` package) for `i2c-piix4`,
  `rmi_smbus`, and `psmouse` with its sub-drivers, plus the community
  per-directory Makefiles. Ubuntu's `i2c-piix4.c` is identical to
  `i2c-piix4.c.orig`; its `rmi_smbus.c`, `synaptics.c`, and
  `psmouse-base.c` differ slightly from the community 7.2.9 copies, which
  is why the Ubuntu files are used. `hgpk.[ch]` (OLPC) had to be added
  because Ubuntu's `psmouse-base.c` includes it unconditionally.
- Patches applied: 0001 (piix4 Host Notify), 0002 (`rmi_smbus` 300 ms
  resume settle), 0003 (`psmouse` doze interval 6 for `LEN2073` and the
  other Windows-listed pads). 0004/0005 are not needed:
  `/etc/modprobe.d/synaptics-smbus.conf` already forces intertouch and
  the harness passes `synaptics_intertouch=1` on insmod.
- Build: `make -C /lib/modules/$(uname -r)/build M=$PWD/exp2 W=1 modules`
  is clean apart from two pre-existing upstream `-Wformat-truncation`
  warnings in `elantech.c` and `vmmouse.c`. All three `vermagic` match.
- Harness: `run-asf-hardware-test.sh exp2` loads the three modules
  (`i2c-piix4`, then `rmi_core` + `rmi_smbus`, then `psmouse`), checks each
  by `srcversion`, and after the upper-right phase runs an automatic
  s2idle suspend of 30 s via `rtcwake -m mem`, verifies `PM: suspend exit`,
  waits for the pad and TrackPoint to return, restarts evtest capture with
  a `-post-resume` suffix, and repeats motion, scroll, clickpad, and
  upper-left phases before the 5 minute soak. Recovery also removes
  `rmi_smbus`. `exp1` (default) is unchanged.
- Hashes: harness
  `16379b3ce6cc613185a6477fe1d9db7bb1b089a35c9e8f18cb9a887a95661ec4`,
  exp2 piix4 `7366a169d8303108f00a12d5ad71fd50c197368098baf70f12d1442e9a089a19`
  (srcversion `70BF56E401B9CE29D7B57D7`), exp2 rmi_smbus
  `44e02610ecc3f0e148a786aa12ef998490dbeda71995721692170206e5eb118e`
  (`6ABFA86ADF95C7893204BD8`), exp2 psmouse
  `783b72d65d92c9d570f232427d2113afca6de91a3bebb54e4885de2a67f241dc`
  (`4435078DD3F106C0E4D56D9`), patch 0002
  `2a4eadbdc363209968c0e6945920b357887f8b063d8ec0d0ac320a1b37bc54d1`,
  patch 0003
  `c8268258e20d3f2018a8a67be55f2c6317f0136539f2b227e00af93329c87a4d`.
- Pass bar: zero fatal events across the whole run including suspend; pad
  and TrackPoint return after resume; post-resume motion at the same
  15 ms cadence with no stale first frame; buttons and clickpad as in run 3.
  Watch for: any `rmi4` or `psmouse` message at resume, a changed frame
  interval after resume, and tap behaviour in free use (0003 should make
  quick taps reliable).

### Run 4 (exp2), 2026-10-23: three modules fine, harness bug at suspend

Boot `12ffda42`, logs in `test-logs/20261023T063411Z-12ffda42/`. First load
of the three patched modules (`i2c_piix4`, `rmi_smbus`, `psmouse`, all
srcversion-verified). Attach at 69.3 s, TrackPoint at 69.5 s. Every phase up
to upper-right passed: one-finger 15.8 ms mean interval, two-finger 15.8 ms,
upper buttons L/M/R all registered, 54 clickpad presses via the TrackPoint
device over the run, 1 collision at 252.5 s recovered on retry 1, zero
errors. Then, at the suspend prompt, the harness exited silently before
`rtcwake` ran: `before_exit="$(journalctl … | grep -c 'PM: suspend exit')"`
counted zero, `grep -c` exits 1 on zero, and `set -e` treated the assignment
as a failure. No suspend happened. Stock recovery verified. Fixed with
`|| true` on both counts; the other `grep -c` uses are inside `printf`/`echo`
arguments and are not affected. Harness hash now
`1399af1cc068c50a83c29ee1664bd36a1c36c44f44bbbe260c4b027132283207`.

Tap data is not comparable between run 3 and run 4 (different usage, no
tap-count protocol); 21 of 70 touches in run 4 were under 150 ms and none
were lost host-side. A dedicated "20 quick taps, count them" phase would be
needed to measure the doze patch; not added, the community measured it.

User report after run 4: **tap-to-click did not work** on the RMI4 path
(GNOME Wayland, `tap-to-click` enabled in gsettings). Kernel side, run 4
contains 24 touches under 180 ms, 7 of them nearly motionless, so tap-shaped
touches reached the kernel; whether libinput produced button events from
them is not captured. Harness additions for run 5: a 20-tap counted phase
(`tap-test`) after two-finger scroll; `udevadm info` for each captured
device; and, if `libinput-tools` is installed, `libinput quirks list`,
`libinput list-devices`, and a standalone
`libinput debug-events --enable-tap --verbose` capture on the pad, which
decides between "libinput cannot tap on this device" and "the desktop did
not apply tapping to the hotplugged device". Harness hash
`1c2a2fbb0f3d675a004e18a182e88cec9e97f9f7efee199cbd0c15b5fea30e28`.
Open question: whether tap worked in run 3 (exp1, no doze patch).

### Run 5 (exp2), 2026-10-23: taps are lost by the pad; harness bug at suspend

Boot `bf94164e`, logs in `test-logs/20261023T064906Z-bf94164e/`. Three
patched modules, `libinput-tools` installed. All phases to upper-right
passed; one `-ENXIO` retry at 205.4 s (the yield caught the pad's notify,
retried, recovered); zero errors.

- **Tap test: 20 taps by the user, 3 touches reached the kernel** (75, 17,
  14 ms, i.e. single frames). The standalone libinput (tapping forced on)
  turned the touches it saw into `BTN_LEFT` tap clicks, and reports
  `pressure-based touch detection (25:30)`, palm threshold 130, quirk
  `AttrThumbPressureThreshold=100`; registered taps had pressure ~60. udev
  tags the device `ID_INPUT_TOUCHPAD=1`, size 96×64 mm. So libinput and
  the desktop are not the problem: **the pad does not report most quick
  taps**, the community's "stock doze" symptom (6 of 20 for them), even
  though patch 0003 should have set doze interval 6 for `LEN2073`
  (`serio1` firmware id `PNP: LEN2073 PNP0f13`; Ubuntu's
  `psmouse_matches_pnp_id` is a plain token match, so it matched). Either
  the write did not take effect or 6 is not enough on this unit.
- Second harness bug at the suspend step: `stop_evtest_logs()` ran
  `kill`/`wait` without `|| true`; `wait` returned 143 and `set -e` ended
  the run before `rtcwake` (no ABORT line, same silent shape as run 4).
  Fixed. The identical code in `cleanup()` runs under `set +e`, which is
  why it never showed there.

Decision for run 6: local patch
`patches/0006-local-psmouse-rmi-power-management-knobs.diff` on top of
0003 adds psmouse parameters `synaptics_rmi_nosleep` (bool) and
`synaptics_rmi_doze_interval` (byte, 0 = per-PnP-ID default) and logs
`intertouch pdata: nosleep=… doze_interval=…` at companion creation, so the
kernel log proves what was passed. The community measured NoSleep at 20/20
taps and 0 pinches (their captures 6–8); doze 6 was their chosen upstream
shape but has not worked here. Run 6 uses NoSleep. The harness takes the
extra parameters as a second argument because `pkexec` drops the
environment.

Hashes: harness
`2122c842f0ee5501a3e147016d06865362028cbb265eee3dd4c28b9662fa45a1` (queued-ENTER drain added after run 5),
exp2 psmouse `45ed3a0f7218603055ccd63f3f7af115d411a92f843fc1b0d4b738ab63bbe00f`
(srcversion `D238E124179CFAAF7B610BC`), patch 0006
`cc96ecbe697cc57f6dc1e0200d5c499395d8d610501bb4c014ca8a481cdbb6b6`;
piix4 and rmi_smbus unchanged.

### Run 6 (exp2 + NoSleep), 2026-10-23: taps fixed; run ended early by user

Boot `0ec60df1`, logs in `test-logs/20261023T073057Z-0ec60df1/`,
`psmouse synaptics_intertouch=1 synaptics_rmi_nosleep=1`. Kernel log:
`psmouse serio1: synaptics: intertouch pdata: nosleep=1 doze_interval=6`,
which also proves run 5 passed doze 6 and that doze 6 alone does not help
this unit.

- **Tap test: 17 of 20 taps reached the kernel** (run 5: 3), each 43–102 ms
  and 3–7 frames (run 5: single frames). The standalone libinput produced
  44 tap clicks over the run. User confirms tap-to-click, clickpad press,
  upper buttons, and TrackPoint all working on the desktop.
- Zero collisions, zero retries, zero errors through idle, motion, scroll,
  tap, and the start of the clickpad phase. User exited the harness during
  the clickpad phase (Ctrl-C); the trap restored stock, verified. A second
  attempt on the same boot was refused by the preflight as designed.
- Suspend/resume still not executed.

Conclusion: on this unit the tap fix is F01 NoSleep, not doze interval 6.
Cost: the sensor does not doze between touches (small idle power cost).
Shipping shape for this laptop: patch 0003's list plus NoSleep for
`LEN2073`, or simply `synaptics_rmi_nosleep=1` in modprobe.d once
persistent.

**Correction (re-verification, 2026-10-23):** the earlier statement that
the clickpad press is only delivered via the TrackPoint device was true
only for the exp1 build (stock psmouse). F3A interrupt count at the end of
each run, and `BTN_LEFT` presses on the pad device:

| Run | Build | fn3a IRQs | pad `BTN_LEFT` | TrackPoint `BTN_LEFT` |
|---|---|---|---|---|
| 2 | exp1 | 0 | 0 | 2 |
| 3 | exp1 | 0 | 0 | 25 |
| 4 | exp2 (doze 6) | 47 | 13 | 54 |
| 5 | exp2 (doze 6) | 46 | 2 | 5 |
| 6 | exp2 (doze 6 + NoSleep) | 87 | 12 | 6 |

With patch 0003 in place the pad's own F3A button function fires and the
clickpad press arrives as `BTN_LEFT` on the pad device, with a finger down
at pressure 40–65; in run 6 the standalone libinput also produced a
clickfinger `BTN_RIGHT` (two-finger press). So on the exp2 build there is
no click-placement limitation; libinput clickpad semantics work. The
TrackPoint-device presses in runs 4–6 are the upper buttons. The exact
mechanism (why a non-zero pdata doze interval makes F3A report) is not
established; it is consistent across all three exp2 runs.

Claim re-verified the same time: run 5 (doze 6 only) 3 of 20 taps at
pressure 63; run 6 (doze 6 + NoSleep) 17 of 20 at pressure 54–71; pdata
line in run 6 shows `doze_interval=6`, so the doze write was in place in
both runs. NoSleep is the tap fix on this unit.

### Run 7 (exp2, community config, NoSleep off), 2026-10-23: full pass incl. suspend

Boot `545e6657`, logs in `test-logs/20261023T074453Z-545e6657/`, psmouse
`synaptics_intertouch=1` only; kernel log `intertouch pdata: nosleep=0
doze_interval=6`. Every phase completed, 762 s on the patched path, zero
fatal events, stock restored and verified.

- **Suspend/resume (first time executed):** `rtcwake -m mem -s 30`,
  `PM: suspend entry (s2idle)` / `PM: suspend exit`, pad and TrackPoint
  back immediately, resume-settle idle at 0 IRQ/s. Post-resume one-finger
  14.9 ms mean (pre 15.7), two-finger 14.3 ms (pre 15.2), max interval
  49 ms (pre 89): no 80 Hz clock after resume, so patch 0002 does its job.
  No kernel messages of any kind between resume and teardown.
- **Tap test without NoSleep: 19 of 20 taps reached the kernel**, 43–176 ms,
  3–10 frames, pressure 55–64, spaced about 1 s. This replicates the
  community's doze-6 result and contradicts run 5 (3 of 20, same config,
  same build). Run 5's tap window holds only 10 frames in total, so the pad
  reported almost nothing then; the cause is not identified (the only
  notable preceding event was an `-ENXIO` retry 6 s before the window).
  NoSleep (run 6, 17 of 20) is therefore not proven necessary; it remains
  an available fallback via `synaptics_rmi_nosleep=1` if tap loss recurs.
- Clickpad on the pad device: 3 presses pre, 6 post resume; F3A fired 120
  times. Upper buttons on the TrackPoint device as before.
- Collisions: 22 retries (16 arbitration loss, 6 NAK-with-notify), all
  recovered on the first retry, none in idle; 11 in the 5 minute soak, 5 in
  the post-resume motion phases, 6 between phases. More than earlier runs
  because this run had far more touch activity (fn12 IRQs 21,629 versus
  3,474 in run 6). Zero `still failing`, zero `code=-6`.

Status against the README pass criteria: all met on the exp2 build with the
community configuration. Open item: run 5's intermittent tap loss, to be
watched during daily-use soak.

User confirms taps felt the same in run 7 (NoSleep off) as in run 6.

Harness `soak` mode added for daily use: same exp2 load, srcversion checks,
health monitoring and automatic stock recovery, no scripted phases and no
evtest/libinput capture; ends on ENTER or Ctrl-C. Still one load per boot.
`pkexec ./run-asf-hardware-test.sh soak` (append `synaptics_rmi_nosleep=1`
only if tap loss recurs). Harness hash
`e59dc91c9d22a466e6f464dee28a331ee854365722a658ee8d1954c781c9e8b7` (soak now starts with a counted 20-tap check, printed on screen).

### Soak 1 (exp2, community config), 2026-10-23/24: 4.8 h awake, 4 suspends, clean

Boot `55199787`, logs in `test-logs/20261023T081136Z-55199787/`
(no after-recovery snapshot: the user force-powered-off the laptop with the
harness still running; nothing persists, the next boot came up on stock).

- Tap check at start: **20 of 20**.
- Awake and monitored on the patched path: 289 min (16,858 one-second
  samples); 3 lid-suspend gaps totalling 361 min; 4 s2idle entry/exit
  pairs in the kernel log, all resumed with the pad present and no messages.
- Collisions: 10 arbitration-loss + 4 NAK retries, all recovered, 0 `still
  failing`, 0 `code=-6`. IRQ 7 idle 88 % of samples, peak 368/s.
- Kernel: no rmi4/psmouse/piix4 message after load apart from the unsigned
  module notice. Taint 0x3000 (out-of-tree, unsigned) only.
- Observation: `rmi4-00.fn3a` stayed at 0 interrupts for the whole session
  (runs 4–7 had 46–120). Whether the user physically clicked at all is
  unknown; the soak mode now starts with a counted 5-click check that
  prints pad-device `BTN_LEFT`, TrackPoint-device `BTN_LEFT` and the F3A
  delta. Harness hash
  `3595aba16fc322ae7a32b8b6e026ee2207d36252f7e42c5e7afbadc7cd53a0d4`.

### DKMS tree prepared, 2026-10-24 (not installed)

`dkms/` follows the community layout: pristine files from Ubuntu
`linux-source-7.0.0` 7.0.0-38.38 (`KERNEL_SOURCE`), the community makefiles,
patches 0001–0003 + local 0006, `dkms.conf` (package `p14s-touchpad/0.1`,
three modules to `/updates`, `AUTOINSTALL`), `tools/pre-build.sh` (series
mismatch warning), `tools/refresh-sources.sh` (re-extract from the installed
Ubuntu source tarball), `tools/try-patches.sh build` (what DKMS will do), and
`tools/touchpad-check` (DKMS copies loaded? pad on RMI4?). `try-patches.sh
build` yields srcversions identical to the validated exp2 modules
(piix4 `70BF56E401B9CE29D7B57D7`, rmi_smbus `6ABFA86ADF95C7893204BD8`,
psmouse `D238E124179CFAAF7B610BC`). The community package itself was not
used: its sources are kernel.org 7.2.9, which would drop Ubuntu's psmouse
changes and may not build against 7.0 headers. `dkms` is not installed;
install steps are in `dkms/README.md` and need sudo.

### Soak 2 (short), 2026-10-24: click check answers the F3A question

Boot `69a3a1f6`, logs in `test-logs/20261024T011634Z-69a3a1f6/`. Tap check
22 touches for 20 taps (none lost). **Click check: pad device `BTN_LEFT` 2,
TrackPoint device 0, F3A interrupts 6.** The physical click lands on the
pad device through F3A on this build; the 0 F3A count during soak 1 means
the user never physically clicked in that session (taps only). The soak
itself ended after 47 s because ENTER was pressed at the SOAK prompt, which
is the "end session" key; a second attempt on the same boot was refused by
the one-load-per-boot preflight as designed. Zero collisions, zero errors,
stock restored. Harmless `printf: write error: Broken pipe` from
`input_map` silenced; harness hash
`52a2d975c1754b06990dd8a90f591820d4856823f2a95c25f894182b59741d4a`.

All open observations are now closed.

### DKMS installed, 2026-10-24: first boot partially on DKMS copies

`dkms install p14s-touchpad/0.1` succeeded ("installed (Original modules
exist)"); modules in `/lib/modules/7.0.0-38-generic/updates/dkms/`, and
`modprobe` resolves all three names there. First boot: `i2c_piix4` and
`rmi_smbus` loaded from the DKMS copies and the pad came up on RMI4 by
itself (`Host Notify enabled` once, 0 collisions at check time), but
**`psmouse` was the stock module** (srcversion `4AAE…` not `D238…`): Ubuntu's
initramfs (dated 2026-10-09) carries psmouse, so it loads before the root
filesystem and the `/updates` copy is never used. Consequence on that boot:
patches 0003/0006 inactive (doze 6 and the knobs), the exp1 situation for
taps and clicks. Fix: `sudo update-initramfs -u` and reboot; added to
`dkms/README.md`. `tools/touchpad-check` fixed to resolve module files via
`modinfo -n` (it looked for `i2c_piix4.ko`, the file is `i2c-piix4.ko`) and
to print the initramfs hint. Kernel updates regenerate the initramfs after
DKMS builds, so this is a one-time step per manual install.

After `update-initramfs -u` and a reboot (2026-10-24 07:08): `touchpad-check`
**OK**. All three modules from the DKMS copies, pad on RMI4 at boot with no
harness, kernel log `Host Notify enabled via ASF (IRQ 7)` then `intertouch
pdata: nosleep=0 doze_interval=6` then the F01 probe, 0 collisions in the
first minutes, taint 0x3000 only.

**State: persistent, community configuration, done.** Routine from here:
`~/kernelhack/dkms/tools/touchpad-check` after every boot following a
kernel update; `dkms/README.md` covers the NoSleep fallback, series
refresh, and removal. The harness remains for any future experiment (one
load per boot; it would now have to remove the DKMS copies' modules, which
it does, and recovery would reload them from `/updates`, i.e. "stock" in the
harness sense is now the DKMS build).

## Resume Checklist

1. Read this report and `README.md`. Probe 3 logs are in
   `test-logs/20260725T173705Z-63d9306a/`.
2. Confirm the checkpoint hashes above before editing. Preserve
   `i2c-piix4.c.orig`; do not run the historical `gate*.sh` scripts or
   raw-probe bound address `0x2c`.
3. Experiment 1, on a fresh boot with stock modules loaded and no prior
   patched load: `pkexec ./run-asf-hardware-test.sh`, never manual module
   commands. Stock `rmi_smbus` and `psmouse` stay in place. Pass is zero fatal
   events over the whole run with the pad attached as `rmi4_smbus` and touch,
   two-finger scroll, clickpad press, and the upper left/middle/right buttons
   each working. Record the collision/retry count; it is expected to be
   non-zero. No suspend in this run.
4. Experiment 2 (built, see checkpoint above): on a fresh boot run
   `pkexec ./run-asf-hardware-test.sh exp2`. It includes the automatic
   suspend/resume cycle. Rebuild with
   `make -C /lib/modules/$(uname -r)/build M=$PWD/exp2 modules` after any
   kernel update and re-check `vermagic`.
5. Persistence (DKMS, `apt install dkms`) only after soak and suspend/resume
   pass on later boots. Upstream only if the change stays small and clean.
