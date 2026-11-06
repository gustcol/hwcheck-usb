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

## Beginner guide: making the stick and running the test

No experience needed. You need about 20 minutes to make the stick and about
20 minutes to run the test. Nothing is installed on the machine being tested
and nothing on its disks is changed.

### What you need

- A **USB stick of 4 GB or more**. Everything on it will be erased, so
  copy off anything you want to keep.
- A computer with internet (Windows or Mac) to make the stick.
- For the test itself: the workstation, a monitor, a keyboard, and the stick.

### Part 1: make the stick (on your own computer)

**1. Download the test file.** Click this link and save the file:

> https://github.com/gustcol/hwcheck-usb/releases/download/v2026.11.06/hwcheck-20261106.iso

It's about 760 MB and ends up in your **Downloads** folder as
`hwcheck-20261106.iso`. Don't open it or double-click it. Just leave it
there.

**2. Install balenaEtcher.** This is a free program that copies the file onto
the stick the right way. Go to https://etcher.balena.io, click **Download**,
and install it like any other program. On a Mac, drag it into
Applications.

**3. Plug in the USB stick.** If Windows or the Mac opens a window for it,
just close that window.

**4. Open balenaEtcher.** You'll see three buttons, from left to right:

1. **Flash from file**: click it and pick `hwcheck-20261106.iso` from your
   Downloads folder.
2. **Select target**: click it and tick **only your USB stick**. Check the
   size (for example "8 GB" or "16 GB") and the name so you're sure it's
   the stick. **Don't pick your computer's own disk.** If you're not sure,
   unplug the stick, see which entry disappears, and plug it back in.
3. **Flash!**: click it. The computer may ask for your password or ask
   "allow this app to make changes?". Say yes.

It takes 3 to 10 minutes. balenaEtcher writes the stick and then checks it
by itself. Wait until it says **Flash Complete!**

**5. Ignore any "format" message.** After it finishes, Windows may say
*"You need to format the disk in drive E: before you can use it"*. Click
**Cancel**. Never click "Format disk", because that would erase the stick
you just made. A Mac may say *"The disk you inserted was not readable"*. Click
**Ignore** or **Eject**. Both messages are normal: your computer just can't
read the test system on the stick.

**6. Remove the stick.** Close balenaEtcher and unplug the stick. The stick
is ready, and you only need to make it once.

### Part 2: run the test (on the workstation)

**1. Connect everything.** Plug the monitor cable into the **graphics card**
(the long card with the video outputs on the back, low on the case). Don't
use the motherboard's video outputs, because this processor has no built-in
graphics and those outputs show nothing. Plug in the keyboard and the USB
stick.

**2. Turn the machine on and open the boot menu.** Right after pressing the
power button, tap the boot menu key about once a second until a menu appears:

| Motherboard brand (shown on the first screen) | Key to tap |
|---|---|
| ASUS | `F8` |
| MSI or ASRock | `F11` |
| Gigabyte | `F12` |
| Not sure | try `F12`, then `F11`, then `F8` (restart between tries) |

If Windows or Linux starts normally instead, the key was too late or wrong.
Restart and try again.

**3. Pick the USB stick.** Use the arrow keys and press `Enter`. If the stick
shows up twice, choose the one that starts with **UEFI:**.

**4. Wait.** A menu with a list of options appears. **Don't touch
anything.** After 10 seconds the test starts by itself (the **QUICK** option,
about 16 minutes). The screen shows each check as it runs. The fans will get
loud during the stress tests. That's expected.

**5. Read the result.** At the end a big word fills the screen:

| You see | Meaning |
|---|---|
| **PASSED** (green) | everything works and matches the advertised specs |
| **PASSED WITH WARNINGS** (yellow) | everything works; the lines below explain small notes (for example, it ran a bit hot) |
| **FAILED** (red) | something is wrong or doesn't match; the lines below say what |

Below the word there's one line per part (CPU, RAM, GPU, Disk, Network). Take
a photo of the screen with your phone if you want to keep the result.

**6. Turn it off.** Type `poweroff` and press `Enter`. Wait until the machine
turns off, then remove the stick. Next time it boots normally into its own
system, exactly as before.

### If something goes wrong

| Problem | What to do |
|---|---|
| The stick doesn't appear in the boot menu | Unplug it, plug it into a different USB port (one on the back of the case), and restart. If it still doesn't show up, make the stick again. |
| The screen goes black after the menu and stays black for more than 2 minutes | Hold the power button to turn it off. Start again, and in the menu use the down arrow to choose **"QUICK, safe graphics"**, then press `Enter`. |
| A message about **Secure Boot** or "security violation" appears, or the result says "Secure Boot is on" | Secure Boot must be turned off. Restart, tap `Del` (or `F2`) to enter the BIOS setup, find **Secure Boot** (usually under *Boot* or *Security*), set it to **Disabled**, then choose *Save & Exit*. After the test you can turn it back on. |
| No picture at all on the monitor | The cable is probably in the motherboard. Move it to the graphics card. |
| You need to stop the test early | Press `Ctrl` + `C`. It stops and still shows a result for what it tested. |
| The buyer wants a longer test | In the menu, before the 10 seconds run out, press the down arrow once to choose **FULL** (about 1 hour) and press `Enter`. |

## Step by step for technical users

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
   On Windows use Rufus in "DD image" mode or balenaEtcher. You don't need
   to format the stick first. See [USB stick format](#usb-stick-format)
   for why, and [Writing the stick](#writing-the-stick) for details per OS.
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

## USB stick format

You don't need to format the stick first. Its current format doesn't
matter (FAT32, exFAT, NTFS, GPT or MBR), because writing the image replaces
the whole stick byte for byte, partition table included.

After writing, the stick has this layout:

| Part | What it is |
|------|------------|
| Partition table | **GPT**, with a protective MBR that also holds GRUB's BIOS boot code |
| Partition 1 | 156 KB gap (part of the ISO layout) |
| Partition 2 | 3.3 MB EFI System Partition (FAT), used by UEFI boot |
| Partition 3 | 754 MB ISO 9660 filesystem with the live system |
| Partition 4 | rest of the stick, FAT32 labeled `HWREPORT` (only when written with `make-usb.sh` on Linux) |

This is an "ISO hybrid" image, so the same stick boots on UEFI machines and
on legacy BIOS / CSM machines. Both were tested.

What this means in practice:

- **Write it as a raw image** (dd mode). Don't copy the files onto an
  already formatted stick, and don't use a tool that "extracts" the ISO.
  The boot code won't be there and the stick won't boot.
- **Rufus:** after picking the ISO, Rufus asks how to write it. Choose
  **"Write in DD Image mode"**. The "Partition scheme" and "File system"
  boxes are ignored in that mode, so leave them as they are.
- **balenaEtcher** always writes in raw mode, so there's nothing to choose.
- Windows may say the stick "needs to be formatted" after writing. Click
  **Cancel**. Windows doesn't understand the ISO partition, and formatting
  would erase the stick.
- To use the stick for something else later, format it again normally
  (Windows Disk Management, `diskutil eraseDisk`, or a new partition table
  on Linux).

The optional second **report stick** is a normal stick: FAT32, MBR (or
GPT), volume label `HWREPORT`.

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
