FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive
ARG FLUTTER_VERSION=3.41.6
ARG NODE_VERSION=24.14.1
ARG RUST_VERSION=1.95.0
ARG TARGETARCH

ENV PATH="/opt/flutter/bin:/opt/node/bin:/root/.cargo/bin:${PATH}" \
    FLUTTER_SUPPRESS_ANALYTICS=true \
    PUB_CACHE=/root/.pub-cache

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
      ca-certificates \
      clang \
      cmake \
      curl \
      file \
      fonts-noto-cjk \
      git \
      libgtk-3-dev \
      liblzma-dev \
      libstdc++-12-dev \
      ninja-build \
      pkg-config \
      unzip \
      dbus-x11 \
      imagemagick \
      scrot \
      xdotool \
      xvfb \
      xz-utils \
      zip \
      build-essential \
    && rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    case "${TARGETARCH}" in \
      amd64) node_arch="x64"; flutter_archive="flutter_linux_${FLUTTER_VERSION}-stable.tar.xz" ;; \
      arm64) node_arch="arm64"; flutter_archive="flutter_linux_arm64_${FLUTTER_VERSION}-stable.tar.xz" ;; \
      *) echo "Unsupported Ubuntu client arch: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${node_arch}.tar.xz" -o /tmp/node.tar.xz; \
    mkdir -p /opt/node; \
    tar -xJf /tmp/node.tar.xz -C /opt/node --strip-components=1; \
    rm /tmp/node.tar.xz; \
    curl -fsSL "https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/${flutter_archive}" -o /tmp/flutter.tar.xz; \
    tar -xJf /tmp/flutter.tar.xz -C /opt; \
    rm /tmp/flutter.tar.xz; \
    git config --global --add safe.directory /opt/flutter; \
    flutter config --enable-linux-desktop --no-analytics; \
    flutter precache --linux; \
    curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain "${RUST_VERSION}"; \
    rustup component add llvm-tools-preview

RUN apt-get update \
    && apt-get install -y --no-install-recommends lld-18 llvm-18 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace

CMD ["bash"]
