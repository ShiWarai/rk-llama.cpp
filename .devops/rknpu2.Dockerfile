# Multi-stage image: Rockchip RKNPU2 backend (LLAMA_RKNPU2). Build only for linux/arm64.
# Runtime layout matches .devops/cpu.Dockerfile (full / light / server).

ARG UBUNTU_VERSION=24.04

FROM ubuntu:$UBUNTU_VERSION AS build

ARG TARGETARCH

RUN apt-get update && \
    apt-get install -y gcc-14 g++-14 build-essential git cmake libssl-dev

ENV CC=gcc-14 CXX=g++-14

WORKDIR /app

COPY . .

# TARGETARCH is set by BuildKit; legacy docker build may leave it empty — fall back to uname -m.
# Drop any copied host build/ so CMake does not pick up a foreign CMakeCache paths.
RUN ARCH="${TARGETARCH:-}" && \
    if [ -z "$ARCH" ]; then ARCH="$(uname -m)"; fi && \
    if [ "$ARCH" = "arm64" ] || [ "$ARCH" = "aarch64" ]; then \
        rm -rf build && \
        cmake -S . -B build \
            -DCMAKE_BUILD_TYPE=Release \
            -DGGML_NATIVE=OFF \
            -DLLAMA_BUILD_TESTS=OFF \
            -DGGML_BACKEND_DL=ON \
            -DGGML_CPU_ALL_VARIANTS=ON \
            -DLLAMA_RKNPU2=ON && \
        cmake --build build -j "$(nproc)"; \
    else \
        echo "rknpu2 image: unsupported architecture (need arm64/aarch64), got TARGETARCH=${TARGETARCH} uname=${ARCH}"; \
        exit 1; \
    fi

RUN mkdir -p /app/lib && \
    find build -name "*.so*" -exec cp -P {} /app/lib \; && \
    cp -P ggml/src/ggml-rknpu2/libs/librknnrt.so /app/lib/

RUN mkdir -p /app/full \
    && cp build/bin/* /app/full \
    && cp *.py /app/full \
    && cp -r gguf-py /app/full \
    && cp -r requirements /app/full \
    && cp requirements.txt /app/full \
    && cp .devops/tools.sh /app/full/tools.sh

FROM ubuntu:$UBUNTU_VERSION AS base

RUN apt-get update \
    && apt-get install -y libgomp1 curl libssl3 \
    && apt autoremove -y \
    && apt clean -y \
    && rm -rf /tmp/* /var/tmp/* \
    && find /var/cache/apt/archives /var/lib/apt/lists -not -name lock -type f -delete \
    && find /var/cache -type f -delete

COPY --from=build /app/lib/ /app

FROM base AS full

COPY --from=build /app/full /app

WORKDIR /app

RUN apt-get update \
    && apt-get install -y \
    git \
    python3 \
    python3-pip \
    python3-wheel \
    && pip install --break-system-packages --upgrade setuptools \
    && pip install --break-system-packages -r requirements.txt \
    && apt autoremove -y \
    && apt clean -y \
    && rm -rf /tmp/* /var/tmp/* \
    && find /var/cache/apt/archives /var/lib/apt/lists -not -name lock -type f -delete \
    && find /var/cache -type f -delete

ENTRYPOINT ["/app/tools.sh"]

FROM base AS light

COPY --from=build /app/full/llama-cli /app/full/llama-completion /app/

WORKDIR /app

ENTRYPOINT [ "/app/llama-cli" ]

FROM base AS server

ENV LLAMA_ARG_HOST=0.0.0.0

COPY --from=build /app/full/llama-server /app

WORKDIR /app

HEALTHCHECK CMD [ "curl", "-f", "http://localhost:8080/health" ]

ENTRYPOINT [ "/app/llama-server" ]
