import { quoteShellArg } from "../ssh/session.mjs";

export function verifyCommand(distro) {
  const artifactName = `lico-client-${distro.id}-linux-arm64`;
  const assertSecretServicePlatformBinding = [
    "const fs=require('node:fs')",
    "const report=JSON.parse(fs.readFileSync(process.argv[1],'utf8'))",
    "const secretStore=report.secretStore||{}",
    "const allPrivateKeysBoundToPlatform=secretStore.allPrivateKeysInSelectedCustody===true",
    "const pairingSecretBoundToPlatform=secretStore.pairingSecretInSelectedCustody===true",
    "const ready=report.ok===true&&report.selfTestPassed===true&&report.backend==='linux-secret-service-keyring'&&allPrivateKeysBoundToPlatform&&pairingSecretBoundToPlatform&&secretStore.unsafePersistenceDetected!==true&&report.portableConfigPrivateMaterialRedacted===true&&Number(report.ordinaryFileSecretArtifactCount)===0",
    "if(!ready)process.exit(1)",
    "process.stdout.write(JSON.stringify({ok:true,allPrivateKeysBoundToPlatform,pairingSecretBoundToPlatform,rawPrivateMaterialIncluded:false})+'\\n')",
  ].join(";");
  const secretServiceSessionCommand = (commands) =>
    `dbus-run-session -- bash -lc ${quoteShellArg([
      'export LICO_VM_ORIGINAL_HOME="$HOME"',
      'export CARGO_HOME="$LICO_VM_ORIGINAL_HOME/.cargo"',
      'export RUSTUP_HOME="$LICO_VM_ORIGINAL_HOME/.rustup"',
      'export LICO_VM_SECRET_HOME="$(mktemp -d)"',
      'trap \'rm -rf "$LICO_VM_SECRET_HOME"\' EXIT',
      'export HOME="$LICO_VM_SECRET_HOME"',
      "printf '%s' 'pass' | gnome-keyring-daemon --unlock --components=secrets >/dev/null 2>&1",
      ...commands,
    ].join(" && "))} 2>/dev/null`;
  const ubuntuSecretStoreCommand = secretServiceSessionCommand([
    'export LICOARC_PORTABLE_DIR="$(mktemp -d)"',
    `"$LICO_VM_ORIGINAL_HOME/lico-artifacts/${artifactName}" mobile relay e2ee secret-store-self-test > "$LICO_VM_ORIGINAL_HOME/lico-artifacts/mobile-relay-secret-store-self-test.json"`,
    `node -e ${quoteShellArg(assertSecretServicePlatformBinding)} "$LICO_VM_ORIGINAL_HOME/lico-artifacts/mobile-relay-secret-store-self-test.json"`,
    `node tools/scripts/client-secure-mesh-linux-adaptive-custody-proof.mjs --input-report "$LICO_VM_ORIGINAL_HOME/lico-artifacts/mobile-relay-secret-store-self-test.json" --expect-strategy os_secure_store`,
  ]);
  const ubuntuSecretStoreSelfTest =
    distro.id === "ubuntu" ? [ubuntuSecretStoreCommand] : [];
  const cargoTestCommand =
    distro.id === "ubuntu"
      ? secretServiceSessionCommand([
          "cargo test --manifest-path crates/lico-client-native/Cargo.toml --locked -- --test-threads=1",
        ])
      : "cargo test --manifest-path crates/lico-client-native/Cargo.toml --locked -- --test-threads=1";
  return [
    "set -euo pipefail",
    '. "$HOME/.cargo/env"',
    'cd "$HOME/lico-arc"',
    'export CARGO_TARGET_DIR="$HOME/.cache/licolite/cargo-target"',
    "export CARGO_BUILD_JOBS=1",
    'mkdir -p "$CARGO_TARGET_DIR" "$HOME/lico-artifacts"',
    cargoTestCommand,
    "cargo build --manifest-path crates/lico-client-native/Cargo.toml --locked --release --bin lico-client",
    `cp "$CARGO_TARGET_DIR/release/lico-client" "$HOME/lico-artifacts/${artifactName}"`,
    `chmod 0755 "$HOME/lico-artifacts/${artifactName}"`,
    `"$HOME/lico-artifacts/${artifactName}" --help >/tmp/lico-client-help.txt`,
    "node tools/scripts/client-secure-mesh-linux-adaptive-custody-proof.mjs --self-test",
    `node tools/scripts/client-secure-mesh-release-cli-proof.mjs --cli "$HOME/lico-artifacts/${artifactName}" --platform "${distro.id}-linux-arm64" --report "$HOME/lico-artifacts/secure-mesh-release-cli-proof.json"`,
    `node tools/scripts/client-secure-mesh-linux-adaptive-custody-proof.mjs --cli "$HOME/lico-artifacts/${artifactName}" --platform "${distro.id}-linux-arm64" --report "$HOME/lico-artifacts/secure-mesh-linux-adaptive-custody-proof.json"`,
    `node tools/scripts/client-secure-mesh-linux-package-update-proof.mjs --cli "$HOME/lico-artifacts/${artifactName}" --platform "${distro.id}-linux-arm64" --package-output "$HOME/lico-artifacts/${artifactName}.tar.gz" --report "$HOME/lico-artifacts/secure-mesh-linux-package-update-proof.json"`,
    ...ubuntuSecretStoreSelfTest,
    'uname -a > "$HOME/lico-artifacts/uname.txt"',
    'rustc -Vv > "$HOME/lico-artifacts/rustc.txt"',
    `file "$HOME/lico-artifacts/${artifactName}" > "$HOME/lico-artifacts/file.txt"`,
    `(cd "$HOME/lico-artifacts" && sha256sum "${artifactName}" > SHA256SUMS)`,
  ].join(" && ");
}
