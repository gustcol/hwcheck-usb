#!/usr/bin/env bash
# Write the ISO to a USB stick and, on Linux, add a FAT32 partition labeled
# HWREPORT in the free space so the test report is saved on the stick.
#
#   sudo tools/make-usb.sh out/hwcheck-YYYYMMDD.iso /dev/sdX        (Linux)
#   sudo tools/make-usb.sh out/hwcheck-YYYYMMDD.iso /dev/diskN      (macOS)
#
# EVERYTHING ON THE TARGET DEVICE IS ERASED.
set -euo pipefail

iso=${1:-}
dev=${2:-}
if [ -z "$iso" ] || [ -z "$dev" ] || [ ! -f "$iso" ]; then
    sed -n '2,9p' "$0"
    exit 1
fi
[ "$(id -u)" -eq 0 ] || { echo "run as root (sudo)"; exit 1; }

os=$(uname -s)
case $os in
Linux)
    [ -b "$dev" ] || { echo "$dev is not a block device"; exit 1; }
    [ "$(lsblk -dno TYPE "$dev")" = disk ] || { echo "$dev must be a whole disk, not a partition"; exit 1; }
    if [ "$(lsblk -dno TRAN "$dev")" != usb ]; then
        echo "$dev is not a USB device. Refusing, to protect internal disks."
        exit 1
    fi
    lsblk -o NAME,SIZE,MODEL,MOUNTPOINTS "$dev"
    ;;
Darwin)
    diskutil info "$dev" | grep -qE 'Protocol: +USB' || { echo "$dev is not a USB device. Refusing."; exit 1; }
    diskutil list "$dev"
    ;;
*)
    echo "unsupported OS: $os"
    exit 1
    ;;
esac

read -r -p "ALL DATA on $dev will be erased. Type YES to continue: " answer
[ "$answer" = YES ] || { echo "aborted"; exit 1; }

if [ "$os" = Darwin ]; then
    diskutil unmountDisk "$dev"
    dd if="$iso" of="${dev/disk/rdisk}" bs=4m
    sync
    diskutil eject "$dev" || true
    cat <<'EOF'

Done. macOS can't add the report partition to this kind of image.
The report still shows on screen. To keep a copy, format any second
stick as FAT32 named HWREPORT and plug it in before the test ends:
    diskutil eraseDisk FAT32 HWREPORT MBR /dev/diskM
EOF
    exit 0
fi

for p in $(lsblk -lnpo NAME "$dev" | tail -n +2); do umount "$p" 2>/dev/null || true; done
dd if="$iso" of="$dev" bs=4M conv=fsync status=progress
sync
partprobe "$dev" 2>/dev/null || blockdev --rereadpt "$dev" || true
sleep 2

# The image is GPT with a protective MBR. Its backup GPT header sits at the
# end of the image, not the end of the stick, so move it there first. Then
# add a FAT32 ("Microsoft basic data") partition in the space that's left.
sfdisk --relocate gpt-bak-std "$dev"
echo ',,EBD0A0A2-B9E5-4433-87C0-68B6B72699C7' | sfdisk --append --no-reread "$dev"
partprobe "$dev" 2>/dev/null || blockdev --rereadpt "$dev" || true
sleep 2
part=$(lsblk -lnpo NAME "$dev" | tail -1)
mkfs.vfat -F 32 -n HWREPORT "$part"
sync
lsblk -o NAME,SIZE,FSTYPE,LABEL "$dev"
echo
echo "Done. Boot the target machine from this stick (UEFI or legacy)."
