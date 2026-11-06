#!/bin/bash
# Runs inside a privileged debian:trixie container started by build.sh.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq live-build ca-certificates >/dev/null

LB=/work/live
# Keep the package cache between builds, start everything else fresh
[ -d "$LB/cache" ] && rm -rf /work/lb-cache && mv "$LB/cache" /work/lb-cache
rm -rf "$LB"
mkdir -p "$LB"
[ -d /work/lb-cache ] && mv /work/lb-cache "$LB/cache"
cd "$LB"

lb config \
    --mode debian \
    --distribution trixie \
    --architecture amd64 \
    --archive-areas "main contrib non-free non-free-firmware" \
    --binary-images iso-hybrid \
    --bootloaders "grub-pc grub-efi" \
    --debian-installer none \
    --memtest memtest86+ \
    --apt-recommends false \
    --firmware-binary false \
    --firmware-chroot false \
    --linux-packages "linux-image linux-headers" \
    --chroot-squashfs-compression-type zstd \
    --iso-volume HWCHECK \
    --iso-application hwcheck \
    --iso-publisher hwcheck \
    --image-name hwcheck \
    --bootappend-live "boot=live components quiet loglevel=3 noeject noprompt consoleblank=0 live-config.hostname=hwcheck live-config.noautologin systemd.gpt_auto=0 modprobe.blacklist=nouveau nvidia-drm.modeset=1 nvidia-drm.fbdev=1 nvidia-current-drm.modeset=1 nvidia-current-drm.fbdev=1"

# Our config: package list, hook, systemd/udev files
cp -a /src/live/config/. config/

# hwcheck itself
inc=config/includes.chroot
install -D -m 0755 /src/src/hwcheck "$inc/usr/local/bin/hwcheck"
install -D -m 0755 /src/src/hwcheck-save "$inc/usr/local/bin/hwcheck-save"
install -D -m 0755 /src/src/protect-disk "$inc/usr/local/lib/hwcheck/protect-disk"
install -m 0644 /src/src/lib/*.sh "$inc/usr/local/lib/hwcheck/"
install -D -m 0644 /src/profiles/hwcheck.conf.example "$inc/usr/share/doc/hwcheck/hwcheck.conf.example"
install -D -m 0644 -t "$inc/etc/hwcheck/profiles" /src/profiles/*.conf
install -m 0755 /work/gpu-burn/gpu_burn "$inc/usr/local/lib/hwcheck/gpu_burn"
install -m 0644 /work/gpu-burn/compare.fatbin "$inc/usr/local/lib/hwcheck/compare.fatbin"
install -m 0644 /work/gpu-burn/gpu-burn.LICENSE "$inc/usr/local/lib/hwcheck/gpu-burn.LICENSE" 2>/dev/null || true

# Boot menu: start from the stock templates, then apply ours
mkdir -p config/bootloaders
cp -a /usr/share/live/build/bootloaders/grub-pc config/bootloaders/
cp /src/live/bootloaders/grub-pc/*.cfg config/bootloaders/grub-pc/

lb build 2>&1 | tee /out/build.log

iso=$(find "$LB" -maxdepth 1 -name "*.iso" | head -1)
name=hwcheck-${HWCHECK_VERSION:-$(date +%Y%m%d)}.iso
cp "$iso" "/out/$name"
(cd /out && sha256sum "$name" >"$name.sha256")
chown "${HOST_UID:-0}:${HOST_GID:-0}" /out/* 2>/dev/null || true
