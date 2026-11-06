# hwcheck-usb

A bootable USB stick that checks a used workstation in front of a buyer. Plug
it in, power on, and walk away. About 15 minutes later the screen shows
**PASSED**, **PASSED WITH WARNINGS**, or **FAILED**, plus a short list of
anything that needs attention.

It was built for this machine, but the expected spec is a plain config file
([profiles/target.conf](profiles/target.conf)), so it works for others too:

| Part | Expected |
|------|----------|
| GPU  | NVIDIA Quadro RTX 6000, 24 GB VRAM |
| CPU  | Intel Core i9-10980XE, 18 cores / 36 threads, AVX-512 |
| RAM  | 128 GB |
| Disk | about 2.5 TB in total |

## Step by step: from download to a verdict in front of the buyer

You need a USB stick of 4 GB or more (it gets erased) and, optionally, a
second small stick for the report.

1. **Get the ISO.** Download `hwcheck-YYYYMMDD.iso` and its `.sha256` from
   the [releases](../../releases) page and check it:
   ```bash
   shasum -a 256 -c hwcheck-YYYYMMDD.iso.sha256     # macOS
   sha256sum -c hwcheck-YYYYMMDD.iso.sha256         # Linux
   ```
2. **Write the stick.** Clone this repo and run the helper. It refuses
   anything that isn't a USB device and asks you to type `YES`.
   ```bash
   git clone git@github.com:gustcol/hwcheck-usb.git && cd hwcheck-usb
   diskutil list                                               # macOS: find the stick, e.g. /dev/disk4
   sudo tools/make-usb.sh ~/Downloads/hwcheck-YYYYMMDD.iso /dev/disk4
   lsblk -o NAME,SIZE,TRAN,MODEL                               # Linux: find the stick, e.g. /dev/sdb
   sudo tools/make-usb.sh ~/Downloads/hwcheck-YYYYMMDD.iso /dev/sdb
   ```
   On Windows use Rufus in "DD image" mode. Details per OS are in
   [Writing the stick](#writing-the-stick).
3. **Optional report stick (macOS only).** On Linux the helper already adds
   a `HWREPORT` partition. On macOS, format a second stick:
   `diskutil eraseDisk FAT32 HWREPORT MBR /dev/diskN`.
4. **Prepare the machine.** Plug in monitor, keyboard and the stick. Use a
   monitor port on the Quadro (the i9-10980XE has no integrated graphics).
   Enter the BIOS setup (usually `Del` or `F2` on X299 boards) and make sure
   **Secure Boot is disabled**. Save and exit.
5. **Boot from the stick.** Open the boot menu (`F8` on ASUS, `F11` on
   MSI/ASRock, `F12` on Gigabyte) and pick the USB stick (the `UEFI:` entry
   if there are two).
6. **Let it run.** The menu starts **QUICK** after 10 seconds. Pick **FULL**
   instead if the buyer wants the 1-hour burn-in. The screen shows each
   check as it happens, with a live line of temperatures, clocks and power.
7. **Show the result.** At the end a large **PASSED** (green),
   **PASSED WITH WARNINGS** (yellow) or **FAILED** (red) appears, with one
   line per component and the reason for anything that isn't green.
   `less /run/hwcheck/report.txt` shows every detail. If a HWREPORT
   partition is present, the report (text + HTML + raw logs) is already
   saved on it.
8. **Shut down** with `poweroff` and remove the stick. The machine's own
   OS boots as before. Nothing on its disks was changed.

If the screen goes black right after the menu, reboot and choose
"QUICK, safe graphics".

## The disks are never written

The machine being sold has the seller's data and OS on it, so the stick
treats every internal disk as untouchable:

- A udev rule locks every internal disk and partition **read-only in the
  kernel** the moment it shows up, before any test runs. Only USB devices
  (the boot stick and an optional report stick) stay writable.
- The disk tests only read: SMART data, the drive's own short self-test, and
  a sequential + random read benchmark with `fio --readonly`.
- No swap, no automount, no RAID or LVM assembly. `systemd.gpt_auto=0` is on
  the kernel command line.

`tools/vm-test.sh` proves this on every release: it fills the VM's disks
with random data, runs the full test, and compares SHA-256 checksums before
and after.

## What gets tested

| Step | Tool | Fails when |
|------|------|-----------|
| Inventory | `lscpu`, `dmidecode`, `nvidia-smi`, `lsblk` | CPU model, core/thread count, AVX-512, installed RAM, GPU model, VRAM or total disk size don't match the profile |
| Disk read | `fio` (read-only) | read errors (slow disks only warn) |
| Disk health | `smartctl` | SMART failed, NVMe media errors / critical warning, pending or uncorrectable sectors (wear >= 90% or reallocated sectors warn) |
| GPU stress | [gpu-burn](https://github.com/wilicc/gpu-burn) on 90% of VRAM | any calculation error, GPU drops off the bus |
| CPU stress | `stress-ng --cpu-method matrixprod --verify` on every thread | any wrong result |
| Memory stress | `stressapptest` on ~88% of free RAM | any memory error |
| Full load | gpu-burn + stress-ng at the same time | errors or instability (this is the power supply test) |
| Kernel log | `dmesg` | machine-check (MCE), NVIDIA Xid, disk I/O or uncorrected PCIe errors during the tests |

Temperatures, clocks, power draw and throttling are sampled every 2 seconds
and shown on a live status line. Thermal throttling or very high
temperatures give a warning (weak cooling), not a failure.

## Boot menu

The menu waits 10 seconds, then starts **QUICK** on its own.

| Entry | Time | Notes |
|-------|------|-------|
| QUICK | ~15 min | default; GPU 4 min, CPU 3 min, RAM 4 min, CPU+GPU 2 min |
| FULL burn-in | ~60 min | GPU 15, CPU 15, RAM 20, CPU+GPU 10 min |
| Memory test (memtest86+) | open-ended | standalone RAM test, no OS |
| QUICK, safe graphics | ~15 min | use this if the screen goes black after the menu |
| Shell only | | a root shell with all the tools, no tests |
| Developer > Smoke test | ~3 min | 20 s per test, VM profile, output on the serial port |

Works with UEFI and legacy BIOS. **Secure Boot must be off** (the NVIDIA
module is built for this image and isn't signed). If it's on, the GPU check
fails and says so.

While tests run, `Ctrl+C` stops them and still prints a report. `Alt+F2`
gives a second root shell, handy for `nvidia-smi` or `htop`.

## The report

At the end you get a big verdict on screen and two files in
`/run/hwcheck/`: `report.txt` and `report.html` (plus raw logs). If a FAT
partition labeled `HWREPORT` is present on any USB stick, the report and
logs are copied there automatically. `make-usb.sh` creates that partition
on Linux. Plugging a stick in later and running `hwcheck-save` works too.

## Writing the stick

Download the ISO from the [releases](../../releases) page, or build it (see
below). Check it with `sha256sum -c hwcheck-*.iso.sha256`.

**Linux** (adds the HWREPORT partition):

```bash
sudo tools/make-usb.sh hwcheck-YYYYMMDD.iso /dev/sdX
```

**macOS:**

```bash
diskutil list                      # find the stick, e.g. /dev/disk4
sudo tools/make-usb.sh hwcheck-YYYYMMDD.iso /dev/disk4
```

macOS can't add the report partition to this image. If you want the report
saved, format a second stick as FAT32 named `HWREPORT`
(`diskutil eraseDisk FAT32 HWREPORT MBR /dev/diskN`) and plug it in too.

**Windows:** Rufus in "DD image" mode, or balenaEtcher.

The script refuses anything that isn't a USB device and asks you to type
`YES` before it erases the stick.

## Building

Needs a Linux host with Docker and about 20 GB free. The build runs in
containers, so nothing is installed on the host.

```bash
./build.sh            # -> out/hwcheck-YYYYMMDD.iso
```

What it does:

1. Clones gpu-burn at a pinned commit and compiles it in
   `nvidia/cuda:12.4.1-devel` with cuBLAS linked statically and pruned to
   Turing (sm_75) and Ampere (sm_86). The image then only needs the
   driver's `libcuda.so.1`.
2. Runs Debian `live-build` (trixie) in a privileged `debian:trixie`
   container. The NVIDIA 550 driver from Debian non-free is compiled with
   DKMS for the image kernel; the build fails if the module is missing.

Useful variables: `GPU_ARCHS="75 86 89"` adds Ada support,
`GPU_BURN_COMMIT=...` pins another gpu-burn version.

## Testing

```bash
tests/run.sh                                   # parser unit tests (bash + jq)
shellcheck -x src/hwcheck src/lib/*.sh tools/*.sh build.sh
sudo tools/vm-test.sh out/hwcheck-*.iso ovmf     # on a Proxmox VE host
sudo tools/vm-test.sh out/hwcheck-*.iso seabios default
```

`vm-test.sh` creates a throwaway VM (4 vCPU, 8 GB, two disks), picks a menu
entry with virtual key presses, reads the report from the serial port,
saves screenshots, checks the disks were untouched, and deletes the VM.

## Using it for another machine

Copy `profiles/target.conf`, change the values, rebuild. Any value set to
`0` is skipped. `GPU_REQUIRED=0` skips the GPU checks entirely.

## Layout

```
src/hwcheck            main script (runs on tty1 at boot)
src/lib/*.sh           inventory, disks, stress, report
src/protect-disk       udev helper that locks disks read-only
profiles/*.conf        expected hardware
live/                  live-build config, boot menu, systemd/udev files
docker/                gpu-burn build
tools/make-usb.sh      write the stick
tools/vm-test.sh       end-to-end VM test on Proxmox
tests/                 unit tests and fixtures
```

## License

MIT for this repository. gpu-burn is BSD-2-Clause, see
`/usr/local/lib/hwcheck/gpu-burn.LICENSE` in the image.
