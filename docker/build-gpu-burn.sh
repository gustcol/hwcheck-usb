#!/bin/bash
# Runs inside nvidia/cuda:*-devel (started by build.sh). Source in /src
# (read-only), output in /out. cuBLAS and the CUDA runtime are linked
# statically, so the live image only needs the driver's libcuda.so.1.
set -euo pipefail
CU=/usr/local/cuda
read -r -a archs <<<"${GPU_ARCHS:-75 86}"
gencode=()
for a in "${archs[@]}"; do
    gencode+=(-gencode "arch=compute_$a,code=sm_$a")
done

work=$(mktemp -d)
cp -r /src/. "$work/"
cd "$work"

# Compare kernel: native code for each arch plus PTX of the oldest for newer GPUs
"$CU/bin/nvcc" "${gencode[@]}" -gencode "arch=compute_${archs[0]},code=compute_${archs[0]}" \
    -fatbin compare.cu -o compare.fatbin
g++ -O3 -std=c++11 -Wno-unused-result -I"$CU/include" -DIS_JETSON=false -c gpu_burn-drv.cpp

# Drop cuBLAS kernels for GPUs we don't target; keeps the binary small
mkdir -p libs
for lib in libcublas_static.a libcublasLt_static.a; do
    if ! "$CU/bin/nvprune" "${gencode[@]}" "$CU/lib64/$lib" -o "libs/$lib"; then
        echo "nvprune failed for $lib, using the full library"
        cp "$CU/lib64/$lib" libs/
    fi
done

g++ -o gpu_burn gpu_burn-drv.o -Llibs -L"$CU/lib64" -L"$CU/lib64/stubs" \
    -lcublas_static -lcublasLt_static -lculibos -lcudart_static -lcuda -lpthread -ldl -lrt
strip gpu_burn

cp gpu_burn compare.fatbin /out/
cp LICENSE /out/gpu-burn.LICENSE 2>/dev/null || true
chown -R "${HOST_UID:-0}:${HOST_GID:-0}" /out
ls -la /out
