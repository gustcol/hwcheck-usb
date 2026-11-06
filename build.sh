#!/usr/bin/env bash
# Build the bootable ISO. Needs a Linux host with Docker (BuildKit) and about
# 20 GB of free disk. Output: out/hwcheck-YYYYMMDD.iso
set -euo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
WORK=$ROOT/build
OUT=$ROOT/out
GPU_BURN_COMMIT=${GPU_BURN_COMMIT:-0d19c94dcb2e9b6858b7586a4c327674cd67113b}
CUDA_IMAGE=${CUDA_IMAGE:-nvidia/cuda:12.4.1-devel-ubuntu22.04}
GPU_ARCHS=${GPU_ARCHS:-75 86}
DEBIAN_IMAGE=${DEBIAN_IMAGE:-debian:trixie}

mkdir -p "$WORK" "$OUT"

echo "==> Building gpu-burn ($GPU_BURN_COMMIT, archs $GPU_ARCHS)"
if [ ! -x "$WORK/gpu-burn/gpu_burn" ] || [ "$(cat "$WORK/gpu-burn/gpu-burn.commit" 2>/dev/null)" != "$GPU_BURN_COMMIT" ]; then
    rm -rf "$WORK/gpu-burn"
    docker build -f "$ROOT/docker/gpu-burn.Dockerfile" --target build -t hwcheck-gpu-burn:build \
        --build-arg CUDA_IMAGE="$CUDA_IMAGE" \
        --build-arg GPU_BURN_COMMIT="$GPU_BURN_COMMIT" \
        --build-arg GPU_ARCHS="$GPU_ARCHS" \
        "$ROOT/docker"
    cid=$(docker create hwcheck-gpu-burn:build)
    docker cp "$cid:/out" "$WORK/gpu-burn"
    docker rm "$cid" >/dev/null
fi

echo "==> Building the live image"
docker run --rm --privileged \
    -v "$ROOT:/src:ro" -v "$WORK:/work" -v "$OUT:/out" \
    -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
    "$DEBIAN_IMAGE" bash /src/live/build-in-container.sh

echo "==> Done"
ls -lh "$OUT"/*.iso
