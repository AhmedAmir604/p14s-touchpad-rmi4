#!/bin/bash
# DKMS PRE_BUILD hook: warn when the kernel being built for is not the
# Ubuntu series the pristine sources in drivers/ came from (KERNEL_SOURCE).
# A driver from another series can compile and still misbehave; refresh with
# tools/refresh-sources.sh after installing the matching linux-source package.
#   $1  kernel version DKMS is building for (kernelver), e.g. 7.0.0-39-generic
set -euo pipefail
top=$(cd "$(dirname "$0")/.." && pwd)
want=$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+-[0-9]+' "$top/KERNEL_SOURCE" | head -n 1)
have=${1:?kernelver}
want_series=${want%.*}            # 7.0.0-38 -> 7.0
have_series=${have%%-*}; have_series=${have_series%.*}
if [[ $want_series != "$have_series" ]]; then
	cat >&2 <<MSG
p14s-touchpad: WARNING: sources are from Ubuntu kernel $want (series $want_series)
but this build is for $have (series $have_series). Building anyway; run
tools/refresh-sources.sh after installing linux-source for the new series,
then 'dkms build/install' again, and check with tools/touchpad-check.
MSG
fi
exit 0
