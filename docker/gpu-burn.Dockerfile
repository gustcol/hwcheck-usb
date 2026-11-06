# Builds a self-contained gpu-burn: cuBLAS and the CUDA runtime are linked
# statically, so the live image only needs the NVIDIA driver (libcuda.so.1).
ARG CUDA_IMAGE=nvidia/cuda:12.4.1-devel-ubuntu22.04
FROM ${CUDA_IMAGE} AS build
ARG GPU_BURN_COMMIT
ARG GPU_ARCHS="75 86"
RUN apt-get update && apt-get install -y --no-install-recommends git ca-certificates \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /src
RUN git clone https://github.com/wilicc/gpu-burn . && git checkout "${GPU_BURN_COMMIT}"
COPY build-gpu-burn.sh /build-gpu-burn.sh
RUN GPU_ARCHS="${GPU_ARCHS}" bash /build-gpu-burn.sh

FROM scratch
COPY --from=build /out/ /
