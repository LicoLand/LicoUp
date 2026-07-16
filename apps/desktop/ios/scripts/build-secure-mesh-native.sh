#!/bin/sh
set -euo pipefail

if [ "${ACTION:-}" = "clean" ]; then
  exit 0
fi

REPO_ROOT="$(cd "$PROJECT_DIR/../../.." && pwd)"
MANIFEST="$REPO_ROOT/crates/lico-client-native/Cargo.toml"
OUT_ROOT="$PROJECT_DIR/Flutter/ephemeral/secure_mesh_ios"
LINK_DIR="$OUT_ROOT/link/${PLATFORM_NAME:-unknown}"
MANAGED_CARGO_TARGET="$REPO_ROOT/build/crates/lico-client-native/target"
mkdir -p "$LINK_DIR"

if ! command -v cargo >/dev/null 2>&1; then
  echo "cargo is required to build Secure Mesh iOS native runtime." >&2
  exit 1
fi
if ! command -v node >/dev/null 2>&1; then
  echo "node is required to acquire the managed Cargo artifact lease." >&2
  exit 1
fi

build_rust_target() {
  RUST_TARGET="$1"
  if command -v rustup >/dev/null 2>&1 && ! rustup target list --installed | grep -qx "$RUST_TARGET"; then
    echo "Rust target $RUST_TARGET is missing. Run: rustup target add $RUST_TARGET" >&2
    exit 1
  fi
  SDKROOT="$(xcrun --sdk macosx --show-sdk-path)" \
    node "$REPO_ROOT/tools/scripts/cargo-client.mjs" \
      build --manifest-path "$MANIFEST" --target "$RUST_TARGET" --release --lib
}

case "${PLATFORM_NAME:-}" in
  iphoneos)
    build_rust_target "aarch64-apple-ios"
    cp "$MANAGED_CARGO_TARGET/aarch64-apple-ios/release/liblico_client_native.a" \
      "$LINK_DIR/liblico_client_native.a"
    ;;
  iphonesimulator)
    REQUESTED_ARCHS="${ARCHS:-}"
    if [ -z "$REQUESTED_ARCHS" ] || [ "$REQUESTED_ARCHS" = "undefined_arch" ]; then
      REQUESTED_ARCHS="${NATIVE_ARCH_ACTUAL:-$(uname -m)}"
    fi
    NEED_ARM64=0
    NEED_X86_64=0
    for ARCH in $REQUESTED_ARCHS; do
      case "$ARCH" in
        arm64)
          NEED_ARM64=1
          ;;
        x86_64)
          NEED_X86_64=1
          ;;
        undefined_arch)
          ;;
        *)
          echo "Unsupported iOS simulator architecture: ${ARCH:-unknown}" >&2
          exit 1
          ;;
      esac
    done
    if [ "$NEED_ARM64" -eq 0 ] && [ "$NEED_X86_64" -eq 0 ]; then
      case "${NATIVE_ARCH_ACTUAL:-$(uname -m)}" in
        arm64)
          NEED_ARM64=1
          ;;
        x86_64)
          NEED_X86_64=1
          ;;
      esac
    fi

    ARM64_LIB="$MANAGED_CARGO_TARGET/aarch64-apple-ios-sim/release/liblico_client_native.a"
    X86_64_LIB="$MANAGED_CARGO_TARGET/x86_64-apple-ios/release/liblico_client_native.a"
    if [ "$NEED_ARM64" -eq 1 ]; then
      build_rust_target "aarch64-apple-ios-sim"
    fi
    if [ "$NEED_X86_64" -eq 1 ]; then
      build_rust_target "x86_64-apple-ios"
    fi
    if [ "$NEED_ARM64" -eq 1 ] && [ "$NEED_X86_64" -eq 1 ]; then
      lipo -create "$ARM64_LIB" "$X86_64_LIB" \
        -output "$LINK_DIR/liblico_client_native.a"
    elif [ "$NEED_ARM64" -eq 1 ]; then
      cp "$ARM64_LIB" "$LINK_DIR/liblico_client_native.a"
    elif [ "$NEED_X86_64" -eq 1 ]; then
      cp "$X86_64_LIB" "$LINK_DIR/liblico_client_native.a"
    else
      echo "No supported iOS simulator architecture requested." >&2
      exit 1
    fi
    ;;
  *)
    echo "Unsupported Secure Mesh iOS build platform: ${PLATFORM_NAME:-unknown}" >&2
    exit 1
    ;;
esac
