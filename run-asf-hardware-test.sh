#!/usr/bin/env bash
#
# One patched load per fresh boot.  This script always attempts to restore the
# stock PS/2 path on exit; reboot remains the definitive IRQ-route cleanup.

set -Eeuo pipefail
shopt -s nullglob

export PATH=/usr/sbin:/usr/bin:/sbin:/bin

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# exp1 (default): patched i2c-piix4 only, stock rmi_smbus and psmouse.
# exp2: the three modules from exp2/ (piix4 + rmi_smbus resume settle +
#       psmouse doze interval) and an s2idle suspend/resume cycle mid-run.
readonly MODE="${1:-exp1}"
# Second argument: extra psmouse parameters for exp2 (pkexec drops the
# environment, so this cannot be an env var), e.g. "synaptics_rmi_nosleep=1".
readonly PSMOUSE_EXTRA="${2:-}"
case "${MODE}" in
exp1)
	readonly MODULE_PATH="${SCRIPT_DIR}/i2c-piix4.ko"
	readonly RMI_SMBUS_PATH=""
	readonly PSMOUSE_PATH=""
	;;
exp2|soak)
	# soak: the exp2 modules, no scripted phases; health monitoring and
	# stock recovery stay active until ENTER or Ctrl-C.
	readonly MODULE_PATH="${SCRIPT_DIR}/exp2/drivers/i2c/busses/i2c-piix4.ko"
	readonly RMI_SMBUS_PATH="${SCRIPT_DIR}/exp2/drivers/input/rmi4/rmi_smbus.ko"
	readonly PSMOUSE_PATH="${SCRIPT_DIR}/exp2/drivers/input/mouse/psmouse.ko"
	;;
*)
	echo "usage: $0 [exp1|exp2|soak] [extra psmouse params for exp2/soak]" >&2
	exit 2
	;;
esac
readonly SUSPEND_SECONDS=30
readonly EXPECTED_DMI_VENDOR="LENOVO"
readonly EXPECTED_DMI_PRODUCT="21A0003QUS"
readonly EXPECTED_DMI_VERSION="ThinkPad P14s Gen 2a"
# Fatal: a transfer still failing after the driver's bounded retries, an
# ASF setup/teardown warning, any RMI failure or reset, or a host timeout.
# Bus collisions and retries are expected with a second master on the bus
# (the pad's Host Notify); they are counted by COUNT_PATTERN, not fatal.
readonly ERROR_PATTERN='ASF: xfer to .* still failing|ASF: failed to request IRQ|ASF: FCH PM region busy|SMB0001 declares no IRQ|RMI4 (DeviceError/-ENXIO|transaction failed)|code=-(5|6|16)|rmi4[^:]*:.*([Ff]ailed|[Ee]rror)|rmi4_physical.*Failed|piix4_smbus.*([Ff]ailed|[Tt]imeout)|SMbus companion is not ready yet|Failed to (read irqs|read F0|read F1|enable mouse|change enabled interrupts)|failed transaction reset'
readonly COUNT_PATTERN='Bus collision!|ASF: xfer to .* lost the bus|ASF: receive bank stuck full|Failed to read irqs, code=-6'
# An isolated NAKed F01 interrupt-status read (run 2: one in 173 s, recovered
# on the next notify) loses one frame and is not fatal; a burst of them is.
readonly SOFT_PATTERN='Failed to read irqs, code=-6'
readonly SOFT_PER_MINUTE_ABORT=3
readonly IRQ_RATE_ABORT=5000

if (( EUID != 0 )); then
	echo "Run this test as root (normally through pkexec)." >&2
	exit 2
fi

for f in "${MODULE_PATH}" ${RMI_SMBUS_PATH:+"${RMI_SMBUS_PATH}"} ${PSMOUSE_PATH:+"${PSMOUSE_PATH}"}; do
	if [[ ! -r "${f}" ]]; then
		echo "Missing ${f}" >&2
		exit 2
	fi
done

# Every experimental module is identified by srcversion against its file.
module_matches()
{
	local name="$1"
	local path="$2"

	[[ -r "/sys/module/${name}/srcversion" ]] &&
		[[ "$(< "/sys/module/${name}/srcversion")" == "$(modinfo -F srcversion "${path}")" ]]
}

# asf_host_notify has sysfs permission 0 in this driver, so the parameter
# file never exists; the loaded module is identified by srcversion instead.
readonly LOCAL_SRCVERSION="$(modinfo -F srcversion "${MODULE_PATH}")"

patched_loaded()
{
	[[ -r /sys/module/i2c_piix4/srcversion ]] &&
		[[ "$(< /sys/module/i2c_piix4/srcversion)" == "${LOCAL_SRCVERSION}" ]]
}

readonly BOOT_ID="$(< /proc/sys/kernel/random/boot_id)"
readonly RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-${BOOT_ID:0:8}"
readonly LOG_ROOT="${SCRIPT_DIR}/test-logs"
readonly LOG_DIR="${LOG_ROOT}/${RUN_ID}"
readonly REPO_UID="$(stat -c %u "${SCRIPT_DIR}")"
readonly REPO_GID="$(stat -c %g "${SCRIPT_DIR}")"
readonly CPU_COUNT="$(nproc)"

mkdir -p "${LOG_DIR}"
exec > >(tee -a "${LOG_DIR}/control.log") 2>&1

MODULES_SWAPPED=0
LIVE_LOG_PID=""
LAST_IRQ_TOTAL=""
EVTEST_PIDS=()

irq7_total()
{
	awk -v cpus="${CPU_COUNT}" '
		$1 == "7:" {
			total = 0
			for (i = 2; i <= cpus + 1; i++)
				total += $i
			print total
			found = 1
		}
		END {
			if (!found)
				print 0
		}
	' /proc/interrupts
}

input_map()
{
	local name_file
	local event
	local name

	for name_file in /sys/class/input/event*/device/name; do
		event="${name_file%/device/name}"
		event="${event##*/}"
		name="$(< "${name_file}")"
		# A grep -q reader may close the pipe early; that is not an error.
		printf '%s\t%s\n' "${event}" "${name}" 2>/dev/null || break
	done
}

quick_snapshot()
{
	local label="$1"
	local dir="${LOG_DIR}/${label}"

	mkdir -p "${dir}"
	date -u +%Y-%m-%dT%H:%M:%SZ > "${dir}/captured-at.txt"
	cut -d' ' -f1 /proc/uptime > "${dir}/uptime-seconds.txt"
	printf '%s\n' "${BOOT_ID}" > "${dir}/boot-id.txt"
	sha256sum "${SCRIPT_DIR}/i2c-piix4.c" "${MODULE_PATH}" \
		${RMI_SMBUS_PATH:+"${RMI_SMBUS_PATH}"} ${PSMOUSE_PATH:+"${PSMOUSE_PATH}"} \
		> "${dir}/sha256.txt"
	lsmod > "${dir}/lsmod.txt"
	cp /proc/interrupts "${dir}/interrupts.txt"
	cp /proc/bus/input/devices "${dir}/input-devices.txt"
	input_map > "${dir}/input-map.tsv"
}

snapshot()
{
	local label="$1"
	local dir="${LOG_DIR}/${label}"
	local journal_status

	mkdir -p "${dir}"
	uname -a > "${dir}/uname.txt"
	printf '%s\n' "${BOOT_ID}" > "${dir}/boot-id.txt"
	sha256sum "${SCRIPT_DIR}/i2c-piix4.c" "${MODULE_PATH}" \
		${RMI_SMBUS_PATH:+"${RMI_SMBUS_PATH}"} ${PSMOUSE_PATH:+"${PSMOUSE_PATH}"} \
		> "${dir}/sha256.txt"
	modinfo "${MODULE_PATH}" > "${dir}/local-module-modinfo.txt"
	lsmod > "${dir}/lsmod.txt"
	cp /proc/interrupts "${dir}/interrupts.txt"
	cp /proc/bus/input/devices "${dir}/input-devices.txt"
	input_map > "${dir}/input-map.tsv"
	if timeout 15s journalctl -k -b --no-pager -o short-monotonic \
		> "${dir}/kernel-journal.txt" \
		2> "${dir}/kernel-journal.stderr.txt"; then
		:
	else
		journal_status=$?
		printf 'journalctl did not complete within 15s (status %d); output may be partial.\n' \
			"${journal_status}" > "${dir}/kernel-journal-warning.txt"
	fi
}

stock_recovery()
{
	local recovery_ok=1

	echo "Restoring the stock PS/2 path..."
	timeout 20s modprobe -r psmouse ||
		echo "WARNING: psmouse removal did not complete cleanly"
	if [[ -d /sys/module/rmi_smbus ]]; then
		timeout 20s modprobe -r rmi_smbus ||
			echo "WARNING: rmi_smbus removal did not complete cleanly"
	fi
	timeout 20s modprobe -r i2c_piix4 ||
		echo "WARNING: patched i2c_piix4 removal did not complete cleanly"
	timeout 20s modprobe i2c_piix4 || recovery_ok=0
	timeout 20s modprobe psmouse || recovery_ok=0
	sleep 3

	if patched_loaded; then
		recovery_ok=0
	fi
	if [[ -n "${RMI_SMBUS_PATH}" ]] && module_matches rmi_smbus "${RMI_SMBUS_PATH}"; then
		recovery_ok=0
	fi
	if [[ -n "${PSMOUSE_PATH}" ]] && module_matches psmouse "${PSMOUSE_PATH}"; then
		recovery_ok=0
	fi
	if ! grep -q 'SynPS/2 Synaptics TouchPad' < <(input_map); then
		recovery_ok=0
	fi
	if ! grep -q 'TrackPoint' < <(input_map); then
		recovery_ok=0
	fi

	if (( recovery_ok )); then
		echo "Stock modules, SynPS/2 touchpad, and TrackPoint are present."
		printf 'stock-restored\n' > "${LOG_DIR}/recovery-status.txt"
	else
		echo "WARNING: automatic stock recovery could not be verified."
		printf 'recovery-unverified\n' > "${LOG_DIR}/recovery-status.txt"
	fi
}

cleanup()
{
	local status=$?
	local pid

	trap - EXIT INT TERM HUP
	set +e

	for pid in "${EVTEST_PIDS[@]}"; do
		kill "${pid}" 2>/dev/null
	done
	for pid in "${EVTEST_PIDS[@]}"; do
		wait "${pid}" 2>/dev/null
	done

	quick_snapshot "before-recovery"
	if [[ -s "${LOG_DIR}/live-kernel.log" ]]; then
		grep -E "${COUNT_PATTERN}" "${LOG_DIR}/live-kernel.log" \
			> "${LOG_DIR}/collisions-and-retries.log"
	fi
	if (( MODULES_SWAPPED )); then
		stock_recovery
	fi

	if [[ -n "${LIVE_LOG_PID}" ]]; then
		kill "${LIVE_LOG_PID}" 2>/dev/null
		wait "${LIVE_LOG_PID}" 2>/dev/null
		LIVE_LOG_PID=""
	fi

	snapshot "after-recovery"
	chown -R "${REPO_UID}:${REPO_GID}" "${LOG_ROOT}"

	echo "Logs: ${LOG_DIR}"
	if (( MODULES_SWAPPED )); then
		echo "A reboot is still required to restore IRQ 7's original route."
	else
		echo "Preflight stopped before any module or IRQ change."
	fi
	exit "${status}"
}

trap cleanup EXIT INT TERM HUP

fail()
{
	echo "ABORT: $*" >&2
	exit 1
}

check_health()
{
	local current_irq
	local delta
	local soft_recent

	if ! patched_loaded; then
		fail "patched module disappeared"
	fi

	if grep -Ev "${SOFT_PATTERN}" "${LOG_DIR}/live-kernel.log" |
	   grep -Eiq "${ERROR_PATTERN}"; then
		grep -Ev "${SOFT_PATTERN}" "${LOG_DIR}/live-kernel.log" |
			grep -Ei "${ERROR_PATTERN}" | tail -n 20
		fail "a transport or RMI error appeared in the kernel log"
	fi

	soft_recent="$(awk -v now="$(cut -d' ' -f1 /proc/uptime)" \
		-v pat="${SOFT_PATTERN}" '
		$0 ~ pat {
			ts = $0
			sub(/^\[ */, "", ts)
			sub(/\].*/, "", ts)
			if (ts + 0 > now - 60)
				n++
		}
		END { print n + 0 }' "${LOG_DIR}/live-kernel.log")"
	if (( soft_recent > SOFT_PER_MINUTE_ABORT )); then
		grep -E "${SOFT_PATTERN}" "${LOG_DIR}/live-kernel.log" | tail -n 5
		fail "${soft_recent} NAKed interrupt-status reads within one minute"
	fi

	current_irq="$(irq7_total)"
	if [[ -n "${LAST_IRQ_TOTAL}" ]]; then
		delta=$((current_irq - LAST_IRQ_TOTAL))
		printf '%s\t%s\t%s\t%s\t%s\n' \
			"$(cut -d' ' -f1 /proc/uptime)" \
			"${CURRENT_PHASE:-monitor}" "${current_irq}" "${delta}" \
			"$(grep -Ec "${COUNT_PATTERN}" "${LOG_DIR}/live-kernel.log")" \
			>> "${LOG_DIR}/irq7-rate.tsv"
		if (( delta > IRQ_RATE_ABORT )); then
			fail "IRQ 7 increased by ${delta} in one second"
		fi
	fi
	LAST_IRQ_TOTAL="${current_irq}"
}

guarded_seconds()
{
	local seconds="$1"
	local phase="$2"
	local remaining

	CURRENT_PHASE="${phase}"
	printf '%s\t%s\tstart\n' "$(cut -d' ' -f1 /proc/uptime)" "${phase}" \
		>> "${LOG_DIR}/phases.tsv"
	for ((remaining = seconds; remaining > 0; remaining--)); do
		check_health
		if (( remaining == seconds || remaining % 5 == 0 )); then
			echo "${phase}: ${remaining}s remaining"
		fi
		sleep 1
	done
	check_health
	printf '%s\t%s\tend\n' "$(cut -d' ' -f1 /proc/uptime)" "${phase}" \
		>> "${LOG_DIR}/phases.tsv"
}

wait_for_enter()
{
	local prompt="$1"

	# Discard ENTERs typed during the previous phase, otherwise they
	# answer this prompt instantly (run 4/5 phases ran back to back).
	while IFS= read -r -t 0.2; do :; done
	echo
	echo "${prompt}"
	echo "Waiting for ENTER while health monitoring continues..."
	while ! IFS= read -r -t 1; do
		CURRENT_PHASE="waiting"
		check_health
	done
}

start_evtest_logs()
{
	local suffix="${1:-}"
	local event
	local name
	local output

	input_map > "${LOG_DIR}/rmi-input-map${suffix}.tsv"
	while IFS=$'\t' read -r event name; do
		case "${name}" in
		"Synaptics TM3471-030"|*"TrackPoint"*)
			output="${LOG_DIR}/evtest-${event}${suffix}.log"
			echo "Capturing /dev/input/${event}: ${name}"
			stdbuf -oL -eL evtest "/dev/input/${event}" \
				> "${output}" 2>&1 &
			EVTEST_PIDS+=("$!")
			udevadm info "/dev/input/${event}" \
				> "${LOG_DIR}/udev-${event}${suffix}.txt" 2>&1 || true
			;;
		esac
		# A standalone libinput with tapping forced on: shows whether
		# libinput itself turns the pad's touches into tap clicks,
		# independent of the desktop's configuration.
		if [[ "${name}" == "Synaptics TM3471-030" ]] && command -v libinput > /dev/null; then
			libinput quirks list "/dev/input/${event}" \
				> "${LOG_DIR}/libinput-quirks${suffix}.txt" 2>&1 || true
			stdbuf -oL -eL libinput debug-events --device "/dev/input/${event}" \
				--enable-tap --verbose \
				> "${LOG_DIR}/libinput-${event}${suffix}.log" 2>&1 &
			EVTEST_PIDS+=("$!")
		fi
	done < "${LOG_DIR}/rmi-input-map${suffix}.tsv"
	if command -v libinput > /dev/null; then
		libinput list-devices > "${LOG_DIR}/libinput-list-devices${suffix}.txt" 2>&1 || true
	else
		echo "NOTE: libinput CLI not installed (apt install libinput-tools); tap analysis will be kernel-side only"
	fi
}

stop_evtest_logs()
{
	local pid

	# Under set -e a kill of an exited pid, or wait returning the killed
	# process's status (143), would end the run (it did in run 5).
	for pid in "${EVTEST_PIDS[@]}"; do
		kill "${pid}" 2>/dev/null || true
	done
	for pid in "${EVTEST_PIDS[@]}"; do
		wait "${pid}" 2>/dev/null || true
	done
	EVTEST_PIDS=()
}

suspend_resume_phase()
{
	local before_exit
	local after_exit

	wait_for_enter \
		"Next: s2idle suspend for ${SUSPEND_SECONDS}s via rtcwake. HANDS OFF; the machine wakes by itself."
	# grep -c exits 1 on a zero count; under set -e that killed run 4.
	before_exit="$(journalctl -k -b --no-pager | grep -c 'PM: suspend exit' || true)"
	printf '%s\tsuspend\tstart\n' "$(cut -d' ' -f1 /proc/uptime)" \
		>> "${LOG_DIR}/phases.tsv"
	stop_evtest_logs
	cp /proc/interrupts "${LOG_DIR}/interrupts-before-suspend.txt"
	rtcwake -m mem -s "${SUSPEND_SECONDS}" > "${LOG_DIR}/rtcwake.log" 2>&1 ||
		fail "rtcwake failed: $(< "${LOG_DIR}/rtcwake.log")"
	sleep 2
	after_exit="$(journalctl -k -b --no-pager | grep -c 'PM: suspend exit' || true)"
	(( after_exit > before_exit )) ||
		fail "kernel log shows no 'PM: suspend exit'; the machine did not suspend"
	printf '%s\tsuspend\tend\n' "$(cut -d' ' -f1 /proc/uptime)" \
		>> "${LOG_DIR}/phases.tsv"
	journalctl -k -b --no-pager -o short-monotonic |
		grep -E 'PM: suspend (entry|exit)' | tail -n 2

	echo "Resumed; waiting for the RMI4 touchpad and TrackPoint to come back..."
	for _ in {1..20}; do
		check_health
		if grep -q 'Synaptics TM3471-030' < <(input_map) &&
		   grep -q 'TrackPoint' < <(input_map); then
			break
		fi
		sleep 1
	done
	grep -q 'Synaptics TM3471-030' < <(input_map) ||
		fail "RMI4 touchpad did not return after resume"
	grep -q 'TrackPoint' < <(input_map) ||
		fail "RMI F03 TrackPoint input did not return after resume"
	guarded_seconds 5 "resume-settle"
	quick_snapshot "post-resume"
	start_evtest_logs "-post-resume"
}

echo "Run ${RUN_ID} (${MODE})"
echo "This script will perform exactly one patched load and then restore stock."

[[ "$(< /sys/class/dmi/id/sys_vendor)" == "${EXPECTED_DMI_VENDOR}" ]] ||
	fail "unexpected system vendor"
[[ "$(< /sys/class/dmi/id/product_name)" == "${EXPECTED_DMI_PRODUCT}" ]] ||
	fail "unexpected DMI product"
[[ "$(< /sys/class/dmi/id/product_version)" == "${EXPECTED_DMI_VERSION}" ]] ||
	fail "unexpected DMI product version"

for f in "${MODULE_PATH}" ${RMI_SMBUS_PATH:+"${RMI_SMBUS_PATH}"} ${PSMOUSE_PATH:+"${PSMOUSE_PATH}"}; do
	[[ "$(uname -r)" == "$(modinfo -F vermagic "${f}" | awk '{print $1}')" ]] ||
		fail "vermagic of ${f} does not match the running kernel"
done
if [[ "${MODE}" == exp2 ]]; then
	command -v rtcwake > /dev/null || fail "rtcwake is required for the suspend phase"
	grep -q mem /sys/power/state || fail "suspend to mem/s2idle is not available"
fi
grep -q '^parm:.*asf_host_notify:' < <(modinfo "${MODULE_PATH}") ||
	fail "local module does not expose asf_host_notify"
if grep -Eq '^parm:.*(poll_hz|xfer_retries|sem_wait_us):' \
	< <(modinfo "${MODULE_PATH}"); then
	fail "local module is an obsolete polling build"
fi

[[ -d /sys/module/i2c_piix4 ]] || fail "stock i2c_piix4 is not loaded"
[[ -d /sys/module/psmouse ]] || fail "stock psmouse is not loaded"
! patched_loaded ||
	fail "a patched i2c_piix4 is already loaded"
if grep -Eq 'event-driven ASF Host Notify enabled|SMBus Host Notify enabled via ASF' \
	< <(journalctl -k -b --no-pager); then
	fail "this boot already contains a patched-module load"
fi
if grep -Eq '^ *7:' /proc/interrupts; then
	grep -E '^ *7:' /proc/interrupts
	fail "IRQ 7 already has a consumer"
fi
grep -q 'SynPS/2 Synaptics TouchPad' < <(input_map) ||
	fail "stock SynPS/2 touchpad baseline is absent"
grep -q 'TrackPoint' < <(input_map) ||
	fail "stock TrackPoint/button-path baseline is absent"

snapshot "stock-baseline"
touch "${LOG_DIR}/live-kernel.log"
stdbuf -oL -eL journalctl -k -b -n 0 -f -o short-monotonic \
	> "${LOG_DIR}/live-kernel.log" 2>&1 &
LIVE_LOG_PID=$!
sleep 1

MODULES_SWAPPED=1
echo "Removing stock psmouse and i2c_piix4..."
timeout 20s modprobe -r psmouse ||
	fail "could not remove stock psmouse"
if [[ -d /sys/module/rmi_smbus ]]; then
	timeout 20s modprobe -r rmi_smbus ||
		fail "could not remove stock rmi_smbus"
fi
timeout 20s modprobe -r i2c_piix4 ||
	fail "could not remove stock i2c_piix4"

echo "Loading the local module's i2c-smbus dependency..."
modprobe i2c_smbus ||
	fail "could not load i2c_smbus"

echo "Loading event-driven module..."
insmod "${MODULE_PATH}" asf_host_notify=1 ||
	fail "patched module insertion failed"
patched_loaded ||
	fail "loaded i2c_piix4 srcversion does not match the local module"

# Collisions and retries are dev_dbg in this driver; make only those lines
# visible.  Enabling all of the module's dev_dbg (run 2) logged every SMBus
# transaction twice, ~480 printk/s under touch, which is its own load.
if ! { echo 'module i2c_piix4 format "ASF:" +p' &&
       echo 'module i2c_piix4 format "Bus collision" +p'; } \
	> /sys/kernel/debug/dynamic_debug/control; then
	echo "WARNING: could not enable dynamic debug; collision counts will read 0"
fi

grep -q 'SMBus Host Notify enabled via ASF' < <(journalctl -k -b --no-pager) ||
	fail "driver did not report Host Notify enabled"
if ! grep -Eq '^ *7:.*piix4-asf' /proc/interrupts; then
	cp /proc/interrupts "${LOG_DIR}/interrupts-after-insmod.txt"
	fail "IRQ 7 ASF action was not registered"
fi
if ! grep -Eq '^ *7:.*(fasteoi|level).*piix4-asf' /proc/interrupts; then
	cp /proc/interrupts "${LOG_DIR}/interrupts-after-insmod.txt"
	fail "IRQ 7 is not visibly level-triggered"
fi

LAST_IRQ_TOTAL="$(irq7_total)"
if [[ "${MODE}" == exp2 || "${MODE}" == soak ]]; then
	echo "Loading patched rmi_smbus and psmouse..."
	modprobe rmi_core || fail "could not load rmi_core"
	insmod "${RMI_SMBUS_PATH}" || fail "patched rmi_smbus insertion failed"
	module_matches rmi_smbus "${RMI_SMBUS_PATH}" ||
		fail "loaded rmi_smbus srcversion does not match the local module"
	# PSMOUSE_EXTRA: extra psmouse parameters for this run, for example
	# PSMOUSE_EXTRA="synaptics_rmi_nosleep=1" (see patches/0006-local-*).
	echo "psmouse parameters: synaptics_intertouch=1 ${PSMOUSE_EXTRA:-}"
	printf '%s\n' "synaptics_intertouch=1 ${PSMOUSE_EXTRA:-}" \
		> "${LOG_DIR}/psmouse-parameters.txt"
	# shellcheck disable=SC2086
	insmod "${PSMOUSE_PATH}" synaptics_intertouch=1 ${PSMOUSE_EXTRA:-} ||
		fail "patched psmouse insertion failed"
	module_matches psmouse "${PSMOUSE_PATH}" ||
		fail "loaded psmouse srcversion does not match the local module"
else
	echo "Reloading psmouse with synaptics_intertouch=1..."
	modprobe psmouse synaptics_intertouch=1 ||
		fail "psmouse intertouch load failed"
fi

echo "Waiting for the RMI4 touchpad and F03 TrackPoint input devices..."
for _ in {1..20}; do
	check_health
	if grep -q 'Synaptics TM3471-030' < <(input_map) &&
	   grep -q 'TrackPoint' < <(input_map); then
		break
	fi
	sleep 1
done
grep -q 'Synaptics TM3471-030' < <(input_map) ||
	fail "RMI4 touchpad did not appear"
grep -q 'TrackPoint' < <(input_map) ||
	fail "RMI F03 TrackPoint input did not appear; upper buttons are unavailable"

guarded_seconds 3 "probe-settle"
quick_snapshot "rmi-probed"

if [[ "${MODE}" == soak ]]; then
	# A counted tap check first, so tap loss (run 5) is measured, not felt.
	start_evtest_logs "-tap-check"
	wait_for_enter \
		"TAP CHECK: tap (quick, light, no movement) exactly 20 times over 20 seconds."
	guarded_seconds 20 "tap-test"
	echo "Tap check: $(grep -c 'BTN_TOUCH), value 1' "${LOG_DIR}"/evtest-event*-tap-check.log | awk -F: '{s+=$2} END{print s+0}') touches reached the kernel out of 20 taps (run 5 lost 17, runs 6/7 lost 1-3)."
	# Counted physical click check: where does the clickpad switch land?
	fn3a_before="$(awk '/fn3a/ {for(i=2;i<=NF-3;i++) s+=$i} END{print s+0}' /proc/interrupts)"
	wait_for_enter \
		"CLICK CHECK: press the clickpad until it physically clicks, exactly 5 times over 10 seconds."
	guarded_seconds 10 "click-test"
	stop_evtest_logs
	fn3a_after="$(awk '/fn3a/ {for(i=2;i<=NF-3;i++) s+=$i} END{print s+0}' /proc/interrupts)"
	pad_log="$(grep -l 'Input device name: "Synaptics TM3471-030"' "${LOG_DIR}"/evtest-event*-tap-check.log | head -n 1 || true)"
	tp_log="$(grep -l 'Input device name: ".*TrackPoint' "${LOG_DIR}"/evtest-event*-tap-check.log | head -n 1 || true)"
	echo "Click check: pad device BTN_LEFT $(grep -c 'BTN_LEFT), value 1' "${pad_log:-/dev/null}"), TrackPoint device BTN_LEFT $(grep -c 'BTN_LEFT), value 1' "${tp_log:-/dev/null}"), F3A interrupts $((fn3a_after - fn3a_before)) (expected: 5 on the pad device, F3A > 0)."
	# Then the open soak. No evtest/libinput capture: hours of events
	# would be tens of MB. Kernel log, IRQ rate and collision counts are
	# still recorded.
	wait_for_enter \
		"SOAK: use the laptop normally (lid suspend is fine). Press ENTER here to restore stock; any transport error restores it automatically."
	quick_snapshot "test-complete"
	echo "Collisions/retries logged (expected, non-fatal): $(grep -Ec "${COUNT_PATTERN}" "${LOG_DIR}/live-kernel.log")"
	echo "Soak ended by user after $(awk -F'\t' '$2=="probe-settle"&&$3=="end"{s=$1} END{printf "%.0f", '"$(cut -d' ' -f1 /proc/uptime)"'-s}' "${LOG_DIR}/phases.tsv") s with zero detected transport errors."
	exit 0
fi

start_evtest_logs

echo
echo "HANDS OFF the touchpad and upper buttons for the idle baseline."
guarded_seconds 60 "idle-hands-off"

wait_for_enter \
	"Next: move one finger continuously around the touchpad for 15 seconds."
guarded_seconds 15 "one-finger-motion"

wait_for_enter \
	"Next: perform continuous two-finger scrolling for 15 seconds."
guarded_seconds 15 "two-finger-scroll"

wait_for_enter \
	"Next: TAP (quick, light, no movement) exactly 20 times over 20 seconds, about one per second. Count them."
guarded_seconds 20 "tap-test"

wait_for_enter \
	"Next: press and release the lower clickpad five times over 15 seconds."
guarded_seconds 15 "clickpad-press"

wait_for_enter \
	"Next: press the UPPER LEFT physical button five times over 15 seconds."
guarded_seconds 15 "upper-left"

wait_for_enter \
	"Next: press the UPPER MIDDLE physical button five times over 15 seconds."
guarded_seconds 15 "upper-middle"

wait_for_enter \
	"Next: press the UPPER RIGHT physical button five times over 15 seconds."
guarded_seconds 15 "upper-right"

if [[ "${MODE}" == exp2 ]]; then
	suspend_resume_phase

	wait_for_enter \
		"After resume: move one finger continuously around the touchpad for 15 seconds."
	guarded_seconds 15 "one-finger-motion-post-resume"

	wait_for_enter \
		"After resume: perform continuous two-finger scrolling for 15 seconds."
	guarded_seconds 15 "two-finger-scroll-post-resume"

	wait_for_enter \
		"After resume: press the clickpad until it clicks, five times over 15 seconds."
	guarded_seconds 15 "clickpad-press-post-resume"

	wait_for_enter \
		"After resume: press the UPPER LEFT physical button five times over 15 seconds."
	guarded_seconds 15 "upper-left-post-resume"
fi

wait_for_enter \
	"Next: use the touchpad freely (taps, scrolls, clicks, buttons) for 5 minutes."
guarded_seconds 300 "free-use-soak"

echo "Final hands-off cooldown..."
guarded_seconds 10 "cooldown"
quick_snapshot "test-complete"
echo "Collisions/retries logged (expected, non-fatal): $(grep -Ec "${COUNT_PATTERN}" "${LOG_DIR}/live-kernel.log")"
echo "Controlled ${MODE} test completed with zero detected transport errors."
