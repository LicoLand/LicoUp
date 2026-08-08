FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive
ARG FLUTTER_VERSION=3.44.2
ARG NODE_VERSION=24.14.1
ARG NODE_X64_SHA256=84d38715d449447117d05c3e71acd78daa49d5b1bfa8aacf610303920c3322be
ARG NODE_ARM64_SHA256=71e427e28b78846f201d4d5ecc30cb13d1508ca099ef3871889a1256c7d6f67e
ARG FLUTTER_X64_SHA256=b0de1d19754688ec6769c9a067db3b0594479d3d767f971bfecfc132904c8d5e
ARG FLUTTER_COMMIT=c9a6c484230f8b5e408ec57be1ef71dee1e77020
ARG RUST_VERSION=1.95.0
ARG RUSTUP_VERSION=1.28.2
ARG RUSTUP_X64_SHA256=20a06e644b0d9bd2fbdbfd52d42540bdde820ea7df86e92e533c073da0cdd43c
ARG RUSTUP_ARM64_SHA256=e3853c5a252fca15252d07cb23a1bdd9377a8c6f3efa01531109281ae47f841c
ARG TARGETARCH
ARG INSTALL_ROOT_NAME=opt
ARG ADMIN_HOME_NAME=root
ARG TEMP_ROOT_NAME=tmp
ARG APT_LISTS_ROOT_NAME=var

ENV INSTALL_ROOT="/${INSTALL_ROOT_NAME}" \
    ADMIN_HOME="/${ADMIN_HOME_NAME}" \
    BUILD_TEMP_ROOT="/${TEMP_ROOT_NAME}" \
    PATH="/${INSTALL_ROOT_NAME}/flutter/bin:/${INSTALL_ROOT_NAME}/node/bin:/${ADMIN_HOME_NAME}/.cargo/bin:${PATH}" \
    FLUTTER_SUPPRESS_ANALYTICS=true \
    PUB_CACHE="/${ADMIN_HOME_NAME}/.pub-cache"

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
    && rm -rf "/${APT_LISTS_ROOT_NAME}/lib/apt/lists"/*

RUN set -eux; \
    case "${TARGETARCH}" in \
      amd64) node_arch="x64"; node_sha256="${NODE_X64_SHA256}"; rustup_target="x86_64-unknown-linux-gnu"; rustup_sha256="${RUSTUP_X64_SHA256}" ;; \
      arm64) node_arch="arm64"; node_sha256="${NODE_ARM64_SHA256}"; rustup_target="aarch64-unknown-linux-gnu"; rustup_sha256="${RUSTUP_ARM64_SHA256}" ;; \
      *) echo "Unsupported Ubuntu client arch: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl --retry 3 --retry-connrefused --retry-delay 2 -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${node_arch}.tar.xz" -o "${BUILD_TEMP_ROOT}/node.tar.xz"; \
    printf '%s  %s\n' "${node_sha256}" "${BUILD_TEMP_ROOT}/node.tar.xz" | sha256sum -c -; \
    mkdir -p "${INSTALL_ROOT}/node"; \
    tar -xJf "${BUILD_TEMP_ROOT}/node.tar.xz" -C "${INSTALL_ROOT}/node" --strip-components=1; \
    rm "${BUILD_TEMP_ROOT}/node.tar.xz"; \
    if [ "${TARGETARCH}" = "arm64" ]; then \
      git -c advice.detachedHead=false clone --quiet --filter=blob:none --depth 1 --branch "${FLUTTER_VERSION}" https://github.com/flutter/flutter.git "${INSTALL_ROOT}/flutter"; \
      test "$(git -C "${INSTALL_ROOT}/flutter" rev-parse HEAD)" = "${FLUTTER_COMMIT}"; \
    else \
      curl --retry 3 --retry-connrefused --retry-delay 2 -fsSL "https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_${FLUTTER_VERSION}-stable.tar.xz" -o "${BUILD_TEMP_ROOT}/flutter.tar.xz"; \
      printf '%s  %s\n' "${FLUTTER_X64_SHA256}" "${BUILD_TEMP_ROOT}/flutter.tar.xz" | sha256sum -c -; \
      tar -xJf "${BUILD_TEMP_ROOT}/flutter.tar.xz" -C "${INSTALL_ROOT}"; \
      rm "${BUILD_TEMP_ROOT}/flutter.tar.xz"; \
    fi; \
    git config --global --add safe.directory "${INSTALL_ROOT}/flutter"; \
    flutter config --enable-linux-desktop --no-analytics; \
    flutter precache --linux; \
    curl --retry 3 --retry-connrefused --retry-delay 2 -fsSL "https://static.rust-lang.org/rustup/archive/${RUSTUP_VERSION}/${rustup_target}/rustup-init" -o "${BUILD_TEMP_ROOT}/rustup-init"; \
    printf '%s  %s\n' "${rustup_sha256}" "${BUILD_TEMP_ROOT}/rustup-init" | sha256sum -c -; \
    chmod 0700 "${BUILD_TEMP_ROOT}/rustup-init"; \
    "${BUILD_TEMP_ROOT}/rustup-init" -y --profile minimal --default-toolchain "${RUST_VERSION}" --no-modify-path; \
    rm "${BUILD_TEMP_ROOT}/rustup-init"; \
    rustup component add llvm-tools-preview --toolchain "${RUST_VERSION}"

RUN apt-get update \
    && apt-get install -y --no-install-recommends lld-18 llvm-18 \
    && rm -rf "/${APT_LISTS_ROOT_NAME}/lib/apt/lists"/*

WORKDIR /workspace

CMD ["bash"]
