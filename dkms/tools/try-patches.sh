#!/bin/bash
# tools/try-patches.sh [build]
#
# Apply patches/ (in dkms.conf PATCH[] order) to a scratch copy of the tree
# and, with "build", compile it against the running kernel's headers.  This
# is what DKMS does at install time; run it after a source refresh.
set -euo pipefail
top=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cp -r "$top/drivers" "$top/Makefile" "$tmp/"
mapfile -t patches < <(sed -n 's/^PATCH\[[0-9]*\]="\(.*\)"$/\1/p' "$top/dkms.conf")
for p in "${patches[@]}"; do
	echo "== $p"
	patch -d "$tmp" -p1 -s < "$top/patches/$p"
done
if [[ ${1:-} == build ]]; then
	make -C "/lib/modules/$(uname -r)/build" M="$tmp" modules 2>&1 |
		grep -vE 'pahole|compiler differs|built by|You are using|built with|Skipping BTF' || true
	for m in drivers/i2c/busses/i2c-piix4.ko drivers/input/rmi4/rmi_smbus.ko drivers/input/mouse/psmouse.ko; do
		[[ -f $tmp/$m ]] || { echo "BUILD FAILED: $m missing" >&2; exit 1; }
		printf '%-40s vermagic %s srcversion %s\n' "$m" \
			"$(modinfo -F vermagic "$tmp/$m" | awk '{print $1}')" \
			"$(modinfo -F srcversion "$tmp/$m")"
	done
fi
echo "patches apply$([[ ${1:-} == build ]] && echo ' and modules build')"
