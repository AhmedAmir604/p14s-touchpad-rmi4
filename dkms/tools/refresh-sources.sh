#!/bin/bash
# tools/refresh-sources.sh [tarball]
#
# Replace the pristine kernel files in drivers/ with the copies from the
# installed Ubuntu linux-source package (default
# /usr/src/linux-source-<ver>.tar.bz2, the newest found), and record it in
# KERNEL_SOURCE. Then check that the patches still apply:
#
#     tools/refresh-sources.sh && tools/try-patches.sh
set -euo pipefail
top=$(cd "$(dirname "$0")/.." && pwd)
tarball=${1:-$(ls -1 /usr/src/linux-source-*.tar.bz2 2>/dev/null | sort -V | tail -n 1)}
[[ -r $tarball ]] || { echo "no linux-source tarball found; apt install linux-source" >&2; exit 1; }
prefix=$(tar -tjf "$tarball" | head -n 1 | cut -d/ -f1)
files=$(cd "$top" && find drivers -type f \( -name '*.c' -o -name '*.h' \) | sort)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
# shellcheck disable=SC2086
tar -xjf "$tarball" -C "$tmp" $(printf "$prefix/%s\n" $files)
for f in $files; do
	if cmp -s "$tmp/$prefix/$f" "$top/$f"; then
		echo "unchanged  $f"
	else
		cp "$tmp/$prefix/$f" "$top/$f"
		echo "updated    $f"
	fi
done
ver=$(dpkg-query -W -f='${Version}' "linux-source-$(basename "$tarball" .tar.bz2 | sed 's/linux-source-//')" 2>/dev/null || echo unknown)
echo "Ubuntu $(basename "$tarball" .tar.bz2) $ver ($tarball)" > "$top/KERNEL_SOURCE"
echo "KERNEL_SOURCE = $(< "$top/KERNEL_SOURCE")"
