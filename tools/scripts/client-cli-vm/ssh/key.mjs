import { chmodSync, existsSync, mkdirSync, readFileSync } from "node:fs";
import path from "node:path";
import { cacheRoot } from "../paths.mjs";
import { run } from "../process.mjs";

export function ensureSshKey() {
  const sshRoot = path.join(cacheRoot(), "ssh");
  const keyPath = path.join(sshRoot, "id_ed25519");
  mkdirSync(sshRoot, { recursive: true });
  if (!existsSync(keyPath)) {
    run("ssh-keygen", ["-t", "ed25519", "-N", "", "-f", keyPath, "-C", "licoup-cli-vm"], {
      stdio: "ignore",
    });
    chmodSync(keyPath, 0o600);
  }
  return {
    keyPath,
    publicKey: readFileSync(`${keyPath}.pub`, "utf8").trim(),
  };
}
