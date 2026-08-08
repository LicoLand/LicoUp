import {
  linuxProductFlutterCommit,
  linuxProductFlutterVersion,
  linuxProductNodeArm64Sha256,
  linuxProductNodeVersion,
  linuxProductRustupArm64Sha256,
  linuxProductRustupVersion,
  linuxProductRustVersion,
} from "../constants.mjs";

export function linuxProductBootstrapCommand(distro) {
  if (distro.id !== "ubuntu" || distro.packageManager !== "apt") {
    throw new Error("Linux product acceptance currently requires the configured Ubuntu ARM64 VM.");
  }
  return [
    "set -euo pipefail",
    "sudo timeout 180 cloud-init status --wait >/dev/null 2>&1 || true",
    "for attempt in 1 2 3 4 5; do if sudo timeout 240 env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 update >/dev/null 2>&1; then break; fi; [ \"$attempt\" != 5 ] || exit 1; sleep 3; done",
    "for attempt in 1 2 3 4 5; do if sudo timeout 360 env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 install -y build-essential ca-certificates clang cmake curl dbus-x11 docker.io file git libdbus-1-dev libgtk-3-dev liblzma-dev libsecret-1-dev libstdc++-12-dev ninja-build openssl pkg-config python3 rsync tar unzip xdotool xz-utils xvfb zip >/dev/null 2>&1; then break; fi; [ \"$attempt\" != 5 ] || exit 1; sleep 3; done",
    "printf '%s\\n' '{\"step\":\"package_manager_ready\"}'",
    'mkdir -p "$HOME/.local/node" "$HOME/.local" "$HOME/.cache/licomesh"',
    `if [ ! -x "$HOME/.cargo/bin/rustup" ] || ! "$HOME/.cargo/bin/rustup" --version 2>/dev/null | grep -Fq "rustup ${linuxProductRustupVersion} " || [ "$(cat "$HOME/.cache/licomesh/rustup-init.verified" 2>/dev/null || true)" != "${linuxProductRustupArm64Sha256}" ]; then curl --retry 3 --retry-connrefused --retry-delay 2 -fsSL https://static.rust-lang.org/rustup/archive/${linuxProductRustupVersion}/aarch64-unknown-linux-gnu/rustup-init -o "$HOME/.cache/licomesh/rustup-init" && printf '%s  %s\\n' ${linuxProductRustupArm64Sha256} "$HOME/.cache/licomesh/rustup-init" | sha256sum -c - >/dev/null && chmod 0700 "$HOME/.cache/licomesh/rustup-init" && "$HOME/.cache/licomesh/rustup-init" -y --profile minimal --default-toolchain none --no-modify-path >/dev/null 2>&1 && printf '%s\\n' ${linuxProductRustupArm64Sha256} > "$HOME/.cache/licomesh/rustup-init.verified" && rm -f "$HOME/.cache/licomesh/rustup-init"; fi`,
    'export PATH="$HOME/.local/node/bin:$HOME/.local/flutter/bin:$HOME/.cargo/bin:$PATH"',
    `rustup toolchain install ${linuxProductRustVersion} --profile minimal >/dev/null 2>&1`,
    `rustup default ${linuxProductRustVersion} >/dev/null 2>&1`,
    `rustup target add aarch64-unknown-linux-gnu --toolchain ${linuxProductRustVersion} >/dev/null 2>&1`,
    `rustc --version | grep -Fq "rustc ${linuxProductRustVersion} "`,
    "printf '%s\\n' '{\"step\":\"rust_toolchain_ready\"}'",
    `if [ ! -x "$HOME/.local/node/bin/node" ] || [ "$("$HOME/.local/node/bin/node" --version)" != "v${linuxProductNodeVersion}" ] || [ "$(cat "$HOME/.cache/licomesh/node.verified" 2>/dev/null || true)" != "${linuxProductNodeArm64Sha256}" ]; then rm -rf "$HOME/.local/node" && mkdir -p "$HOME/.local/node" && curl --retry 3 --retry-connrefused --retry-delay 2 -fsSL https://nodejs.org/dist/v${linuxProductNodeVersion}/node-v${linuxProductNodeVersion}-linux-arm64.tar.xz -o "$HOME/.cache/licomesh/node.tar.xz" && printf '%s  %s\\n' ${linuxProductNodeArm64Sha256} "$HOME/.cache/licomesh/node.tar.xz" | sha256sum -c - >/dev/null && tar -xJf "$HOME/.cache/licomesh/node.tar.xz" -C "$HOME/.local/node" --strip-components=1 && printf '%s\\n' ${linuxProductNodeArm64Sha256} > "$HOME/.cache/licomesh/node.verified" && rm -f "$HOME/.cache/licomesh/node.tar.xz"; fi`,
    "printf '%s\\n' '{\"step\":\"node_toolchain_ready\"}'",
    `if [ ! -x "$HOME/.local/flutter/bin/flutter" ] || [ "$(git -C "$HOME/.local/flutter" rev-parse HEAD 2>/dev/null || true)" != "${linuxProductFlutterCommit}" ]; then rm -rf "$HOME/.local/flutter" && git -c advice.detachedHead=false clone --quiet --filter=blob:none --depth 1 --branch ${linuxProductFlutterVersion} https://github.com/flutter/flutter.git "$HOME/.local/flutter"; fi`,
    `test "$(git -C "$HOME/.local/flutter" rev-parse HEAD)" = "${linuxProductFlutterCommit}"`,
    'git config --global --add safe.directory "$HOME/.local/flutter"',
    "flutter --version >/dev/null 2>&1",
    "printf '%s\\n' '{\"step\":\"flutter_arm64_source_toolchain_ready\"}'",
    "flutter config --enable-linux-desktop --no-analytics >/dev/null 2>&1",
    "flutter precache --linux >/dev/null 2>&1",
    "sudo systemctl start docker >/dev/null 2>&1",
    "sudo docker info >/dev/null 2>&1",
    "printf '%s\\n' '{\"ok\":true,\"linuxProductToolchainReady\":true}'",
  ].join(" && ");
}
