# p14s-touchpad DKMS tree

RMI4-over-SMBus (InterTouch) for the ThinkPad P14s Gen 2a AMD touchpad on
Ubuntu. Layout and mechanism follow
[orospakr/thinkpad-t14-amd-touchpad](https://github.com/orospakr/thinkpad-t14-amd-touchpad):
pristine kernel files in `drivers/` plus the patches in `patches/`, applied
by DKMS at build time, with the three rebuilt modules installed under
`/updates` so they shadow the stock ones. Differences from that project:

- `drivers/` comes from Ubuntu's own `linux-source` package (see
  `KERNEL_SOURCE`), not kernel.org, so Ubuntu's changes to psmouse are kept.
- Patches 0001–0003 are the community patches unchanged. 0006 is local: it
  adds the psmouse parameters `synaptics_rmi_nosleep` and
  `synaptics_rmi_doze_interval` (inert unless set) and a log line
  `intertouch pdata: nosleep=… doze_interval=…`.
- The community allowlist patches (0004/0005) are not carried;
  `/etc/modprobe.d/synaptics-smbus.conf` (`options psmouse
  synaptics_intertouch=1`) does that job here and must stay.

`tools/try-patches.sh build` produces modules with the same `srcversion`
as the `exp2/` build validated in the hardware runs (see
`../touchpad-rmi4-progress-report.md`).

## Install

```sh
sudo apt install dkms
sudo cp -r ~/kernelhack/dkms /usr/src/p14s-touchpad-0.1
sudo dkms install p14s-touchpad/0.1
sudo update-initramfs -u
sudo reboot
~/kernelhack/dkms/tools/touchpad-check
```

`update-initramfs -u` matters: Ubuntu's initramfs contains psmouse, so
without it the stock psmouse loads early at boot and the DKMS copy is never
used (first install here: pad on RMI4 but psmouse stock, taps/clicks
without patches 0003/0006). Kernel updates regenerate the initramfs after
DKMS has built, so this is only needed after a manual `dkms install`.

The modules are unsigned: Secure Boot must stay off (it is off on this
machine), and the kernel shows the `O` and `E` taint flags. The pad's input
device is named `Synaptics TM3471-030` instead of `SynPS/2 Synaptics
TouchPad`; desktop settings keyed on the old name have to follow.

## Fallback knob

If quick taps are lost again (soak tap check well below 20/20), set the
pad's NoSleep bit without rebuilding:

```sh
echo 'options psmouse synaptics_rmi_nosleep=1' | sudo tee /etc/modprobe.d/p14s-touchpad.conf
sudo reboot
```

## After a kernel update

DKMS rebuilds automatically. Run `tools/touchpad-check`; `NOT OK` means the
stock modules loaded and the pad is back on PS/2. If the new kernel is a
different series (`pre-build.sh` warns in the DKMS log), install the matching
`linux-source` package, then:

```sh
cd /usr/src/p14s-touchpad-0.1
sudo tools/refresh-sources.sh && sudo tools/try-patches.sh build
sudo dkms build p14s-touchpad/0.1 && sudo dkms install p14s-touchpad/0.1
```

## Remove

```sh
sudo dkms remove p14s-touchpad/0.1 --all
sudo reboot
```

DKMS restores the stock modules it replaced.
