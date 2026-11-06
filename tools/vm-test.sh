#!/usr/bin/env bash
# End-to-end test on a Proxmox VE host: boots the ISO in a throwaway VM,
# picks a boot menu entry, waits for the report on the serial port, and
# proves the VM's disks were not written by comparing checksums.
#
#   tools/vm-test.sh ISO_PATH [ovmf|seabios] [menu]
#
#   menu: "smoke" (Developer > Smoke test, VM profile; default)
#         "default" (no key pressed, the boot menu times out into QUICK mode)
#
# Env: VMID (9150), STORAGE (nvme-zfs-vms), BRIDGE (vmbr0), TIMEOUT (900 s)
set -euo pipefail

iso=${1:?usage: vm-test.sh ISO [ovmf|seabios] [smoke|default]}
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

cleanup() {
    [ -n "${socat_pid:-}" ] && kill "$socat_pid" 2>/dev/null
    qm stop "$VMID" --skiplock 1 >/dev/null 2>&1 || true
    qm destroy "$VMID" --purge 1 --destroy-unreferenced-disks 1 >/dev/null 2>&1 || true
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
if [ "$menu" = smoke ]; then
    qm sendkey "$VMID" d
    sleep 2
    screendump 02-developer-menu
    qm sendkey "$VMID" ret
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
    if [ "$menu" = default ] && [ $((SECONDS - start)) -ge 240 ]; then
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
