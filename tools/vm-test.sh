#!/usr/bin/env bash
# End-to-end test on a Proxmox VE host: boots the ISO in a throwaway VM,
# picks a boot menu entry, waits for the report on the serial port, and
# proves the VM's disks were not written by comparing checksums.
#
#   tools/vm-test.sh ISO_PATH [ovmf|seabios] [menu]
#
#   menu: "smoke"      Developer > Smoke test, VM profile (default)
#         "smoke-auto" Developer > Smoke test, any hardware
#         "smoke-usb"  Developer > Smoke test, specs from a USB hwcheck.conf.
#                      Set PROFILE_CONF to the file; it is put on a small FAT
#                      disk attached to the VM as a USB stick.
#         "ask"        Other machines > QUICK, type the specs; every question is
#                      answered with Enter (accept what the VM reports). Stops
#                      after 4 minutes, like "default".
#         "default"    no key pressed, the boot menu times out into QUICK mode
#
# Env: VMID (9150), STORAGE (nvme-zfs-vms), BRIDGE (vmbr0), TIMEOUT (900 s),
#      PROFILE_CONF (for smoke-usb)
set -euo pipefail

iso=${1:?usage: vm-test.sh ISO [ovmf|seabios] [smoke|smoke-auto|smoke-usb|ask|default]}
bios=${2:-ovmf}
menu=${3:-smoke}
VMID=${VMID:-9150}
STORAGE=${STORAGE:-nvme-zfs-vms}
BRIDGE=${BRIDGE:-vmbr0}
TIMEOUT=${TIMEOUT:-900}
OUT=${OUT:-/tmp/hwcheck-vmtest-$VMID-$bios-$menu}
mkdir -p "$OUT"

if qm status "$VMID" >/dev/null 2>&1; then
    echo "VM $VMID already exists, pick another VMID"
    exit 1
fi

case $menu in
smoke | smoke-auto | default | ask) ;;
smoke-usb) [ -r "${PROFILE_CONF:-}" ] || { echo "smoke-usb needs PROFILE_CONF=/path/to/hwcheck.conf"; exit 1; } ;;
*) echo "unknown menu '$menu'"; exit 1 ;;
esac

# shellcheck disable=SC2329 # runs from the EXIT trap
cleanup() {
    # set -e is on: every step here must not fail, or the VM is left behind
    if [ -n "${socat_pid:-}" ]; then kill "$socat_pid" 2>/dev/null || true; fi
    if [ -n "${cfgimg:-}" ]; then rm -f "$cfgimg" || true; fi
    qm stop "$VMID" --skiplock 1 >/dev/null 2>&1 || true
    # The VM can still hold its lock for a few seconds after stopping
    local _
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        qm destroy "$VMID" --purge 1 --destroy-unreferenced-disks 1 >/dev/null 2>&1 && return 0
        sleep 3
    done
    echo "WARNING: could not destroy VM $VMID, remove it by hand (qm destroy $VMID --purge 1)" >&2
}
trap cleanup EXIT

isoname=$(basename "$iso")
isodir=/var/lib/vz/template/iso
cp -f "$iso" "$isodir/$isoname"

args=(--name hwcheck-test --memory 8192 --sockets 1 --cores 4 --cpu host --machine q35
    --scsihw virtio-scsi-single --scsi0 "$STORAGE:32" --sata0 "$STORAGE:16"
    --ide2 "local:iso/$isoname,media=cdrom" --boot order=ide2
    --serial0 socket --vga std --net0 "virtio,bridge=$BRIDGE")
if [ "$bios" = ovmf ]; then
    args+=(--bios ovmf --efidisk0 "$STORAGE:1,efitype=4m,pre-enrolled-keys=0")
fi
if [ "$menu" = smoke-usb ]; then
    # A 64 MB FAT stick holding only hwcheck.conf, attached read-only over USB
    cfgimg=$OUT/profile-stick.img
    truncate -s 64M "$cfgimg"
    mkfs.vfat -n CFGSTICK "$cfgimg" >/dev/null
    cfgmnt=$(mktemp -d)
    mount -o loop "$cfgimg" "$cfgmnt"
    cp "$PROFILE_CONF" "$cfgmnt/hwcheck.conf" || { umount "$cfgmnt"; exit 1; }
    umount "$cfgmnt"
    rmdir "$cfgmnt"
    args+=(--args "-device qemu-xhci,id=cfgxhci -drive file=$cfgimg,format=raw,if=none,id=cfgstick,readonly=on -device usb-storage,bus=cfgxhci.0,drive=cfgstick")
fi
qm create "$VMID" "${args[@]}"

# Fill the test disks with random data and record checksums
disks=()
for key in scsi0 sata0; do
    vol=$(qm config "$VMID" | sed -n "s/^$key: \([^,]*\).*/\1/p")
    disks+=("$(pvesm path "$vol")")
done
for d in "${disks[@]}"; do
    dd if=/dev/urandom of="$d" bs=4M count=256 status=none
    dd if=/dev/urandom of="$d" bs=4M count=64 seek=$(( $(blockdev --getsize64 "$d") / 4194304 - 64 )) status=none
    sync
done
sha_before=$(for d in "${disks[@]}"; do sha256sum "$d" | cut -d' ' -f1; done)
echo "checksums before: $(echo "$sha_before" | paste -sd' ' -)"

qm start "$VMID"
socat -u "UNIX-CONNECT:/var/run/qemu-server/$VMID.serial0" - >"$OUT/serial.log" 2>/dev/null &
socat_pid=$!

screendump() {
    qm monitor "$VMID" <<<"screendump $OUT/$1.ppm" >/dev/null 2>&1 || true
}

sleep 6
screendump 01-bootmenu
# Developer submenu order: VM profile, any hardware, USB hwcheck.conf, target
case $menu in smoke) downs=0 ;; smoke-auto) downs=1 ;; smoke-usb) downs=2 ;; *) downs=-1 ;; esac
if [ "$downs" -ge 0 ]; then
    qm sendkey "$VMID" d
    sleep 2
    for _ in $(seq 1 "$downs"); do
        qm sendkey "$VMID" down
        sleep 0.5
    done
    screendump 02-developer-menu
    qm sendkey "$VMID" ret
elif [ "$menu" = ask ]; then
    qm sendkey "$VMID" o
    sleep 2
    screendump 02-other-machines-menu
    qm sendkey "$VMID" ret
    # Wait for the questions, then press Enter for each of them
    sleep 60
    screendump 02-questions
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        qm sendkey "$VMID" ret
        sleep 1
    done
    screendump 02-answered
fi

start=$SECONDS
n=3
while [ $((SECONDS - start)) -lt "$TIMEOUT" ]; do
    sleep 30
    screendump "$(printf '%02d' $n)-t$((SECONDS - start))"
    n=$((n + 1))
    if grep -q 'VERDICT:' "$OUT/serial.log" 2>/dev/null; then
        sleep 5
        break
    fi
    if { [ "$menu" = default ] || [ "$menu" = ask ]; } && [ $((SECONDS - start)) -ge 240 ]; then
        break
    fi
done
screendump 99-final
qm stop "$VMID" --skiplock 1 >/dev/null 2>&1 || true
sleep 3

sha_after=$(for d in "${disks[@]}"; do sha256sum "$d" | cut -d' ' -f1; done)
echo "checksums after:  $(echo "$sha_after" | paste -sd' ' -)"
if [ "$sha_before" = "$sha_after" ]; then
    echo "DISKS UNCHANGED: OK"
else
    echo "DISKS CHANGED: FAIL"
    exit 2
fi

grep -E 'VERDICT:|^\[' "$OUT/serial.log" | tr -d '\r' | tail -80 || true
echo "Screenshots and serial log in $OUT"
exit 0
