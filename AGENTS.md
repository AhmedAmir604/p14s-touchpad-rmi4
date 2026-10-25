# Repository Guidelines

## Project Structure & Module Organization

This is a flat, out-of-tree Linux kernel module project. `i2c-piix4.c` is the active patched AMD/PIIX4 SMBus driver, while `i2c-piix4.h` contains shared declarations and constants. Preserve `i2c-piix4.c.orig` as the pristine upstream comparison baseline. The root `Makefile` provides the Kbuild entry point. Read `README.md` for the full architecture and recovery procedure, and `touchpad-rmi4-progress-report.md` for the latest experiment status.

Files such as `*.ko`, `*.o`, `*.mod*`, `Module.symvers`, `modules.order`, and hidden `*.cmd` files are generated build artifacts; do not edit them manually.

## Build, Test, and Development Commands

- `make` builds `i2c-piix4.ko` against `/lib/modules/$(uname -r)/build`; install matching kernel headers first.
- `make clean` removes Kbuild-generated outputs.
- `modinfo ./i2c-piix4.ko` verifies the module parameters and that `vermagic` matches the running kernel.
- `diff -u i2c-piix4.c.orig i2c-piix4.c` reviews the complete out-of-tree patch.

## Coding Style & Naming Conventions

Follow Linux kernel C style: tabs for indentation, kernel brace conventions, `snake_case` for functions and variables, and uppercase names for macros. Prefer kernel types such as `u8` where appropriate. Retain SPDX headers, use kernel logging APIs, and pair every user-facing `module_param` with a clear `MODULE_PARM_DESC`. Keep changes narrowly scoped; no formatter or lint configuration is bundled. If a full kernel tree is available, run its `scripts/checkpatch.pl` before submission.

## Testing Guidelines

There is no automated test suite or coverage target. Every change must compile cleanly and receive hardware validation. Follow the latest progress report, perform only one patched-module load attempt per boot, and load only through `run-asf-hardware-test.sh` (the old `poll_hz=60` polling setup is retired; the module has no polling parameter). Record the kernel version, all module parameters, relevant `dmesg` errors, touch/click behavior, and `evtest` frame timing. Polling experiments can wedge the SMBus; keep the documented stock-module reload or reboot recovery path available. Do not make the patch persistent until stability is demonstrated.

## Commit & Pull Request Guidelines

This snapshot contains no usable Git history or PR template. Use focused commits with short, imperative subjects, for example `i2c-piix4: retry transient SMBus failures`. Pull requests should explain the change, tested hardware and kernel, exact parameters, before/after measurements, observed errors, and recovery steps. Update the README or progress report whenever results or known-safe settings change.
