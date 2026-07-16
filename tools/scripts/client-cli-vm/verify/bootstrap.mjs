import {
  linuxProductRustupArm64Sha256,
  linuxProductRustupVersion,
  linuxProductRustVersion,
} from "../constants.mjs";

export function bootstrapCommand(distro) {
  const install = {
    apt: [
      "sudo env DEBIAN_FRONTEND=noninteractive apt-get update",
      "sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl build-essential pkg-config git rsync file tar gzip python3 nodejs libdbus-1-dev dbus-x11 gnome-keyring libsecret-tools",
    ],
    dnf: [
      "sudo dnf -y install ca-certificates curl gcc gcc-c++ make pkgconf-pkg-config git rsync file tar gzip which python3 nodejs dbus-devel dbus-x11 gnome-keyring libsecret",
    ],
    zypper: [
      "sudo zypper --non-interactive refresh",
      "sudo zypper --non-interactive install ca-certificates curl gcc gcc-c++ make pkg-config git rsync file tar gzip which python3 nodejs dbus-1-devel dbus-1-x11 gnome-keyring libsecret-devel",
    ],
    pacman: [
      "sudo pacman -Sy --noconfirm --needed ca-certificates curl base-devel git rsync file tar gzip which python nodejs dbus gnome-keyring libsecret",
    ],
  }[distro.packageManager];
  if (!install) {
    throw new Error(`Unsupported package manager for ${distro.id}: ${distro.packageManager}`);
  }
  return [
    "set -euo pipefail",
    ...install,
    'mkdir -p "$HOME/.cache/licolite"',
    `if [ ! -x "$HOME/.cargo/bin/rustup" ] || ! "$HOME/.cargo/bin/rustup" --version 2>/dev/null | grep -Fq "rustup ${linuxProductRustupVersion} " || [ "$(cat "$HOME/.cache/licolite/rustup-init.verified" 2>/dev/null || true)" != "${linuxProductRustupArm64Sha256}" ]; then curl --retry 3 --retry-connrefused --retry-delay 2 -fsSL https://static.rust-lang.org/rustup/archive/${linuxProductRustupVersion}/aarch64-unknown-linux-gnu/rustup-init -o "$HOME/.cache/licolite/rustup-init" && printf '%s  %s\\n' ${linuxProductRustupArm64Sha256} "$HOME/.cache/licolite/rustup-init" | sha256sum -c - >/dev/null && chmod 0700 "$HOME/.cache/licolite/rustup-init" && "$HOME/.cache/licolite/rustup-init" -y --profile minimal --default-toolchain none --no-modify-path >/dev/null 2>&1 && printf '%s\\n' ${linuxProductRustupArm64Sha256} > "$HOME/.cache/licolite/rustup-init.verified" && rm -f "$HOME/.cache/licolite/rustup-init"; fi`,
    'export PATH="$HOME/.cargo/bin:$PATH"',
    `rustup toolchain install ${linuxProductRustVersion} --profile minimal >/dev/null 2>&1`,
    `rustup default ${linuxProductRustVersion} >/dev/null 2>&1`,
    `rustup target add aarch64-unknown-linux-gnu --toolchain ${linuxProductRustVersion} >/dev/null`,
    "uname -m",
    "rustc --version",
    "cargo --version",
  ].join(" && ");
}
