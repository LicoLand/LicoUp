import { spawnSync } from "node:child_process";

const temporaryException = Object.freeze({
  advisory: "RUSTSEC-2026-0173",
  package: "proc-macro-error2",
  expiresOn: "2026-10-01",
});

function run(command, args) {
  const result = spawnSync(command, args, {
    cwd: process.cwd(),
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
    maxBuffer: 32 * 1024 * 1024,
  });
  if (result.status !== 0) {
    throw new Error(`${command} failed while validating temporary RustSec exceptions`);
  }
  return result.stdout || "";
}

function versionAtLeast(actual, minimum) {
  const left = actual.split(".").map(Number);
  const right = minimum.split(".").map(Number);
  for (let index = 0; index < Math.max(left.length, right.length); index += 1) {
    const difference = (left[index] || 0) - (right[index] || 0);
    if (difference !== 0) return difference > 0;
  }
  return true;
}

const expiry = new Date(`${temporaryException.expiresOn}T00:00:00Z`);
if (!Number.isFinite(expiry.getTime()) || Date.now() >= expiry.getTime()) {
  throw new Error(`${temporaryException.advisory} exception expired; remove or re-audit it`);
}

const activeInverseTree = run("cargo", [
  "tree",
  "--workspace",
  "--locked",
  "-i",
  temporaryException.package,
  "-e",
  "all",
]);
if (activeInverseTree.includes(`${temporaryException.package} v`)) {
  throw new Error(`${temporaryException.advisory} became reachable in the product feature graph`);
}

const rustCfg = run("rustc", ["--print", "cfg"]);
if (rustCfg.split(/\r?\n/u).some((line) => line.trim() === "hax")) {
  throw new Error(`${temporaryException.advisory} exception is invalid when cfg(hax) is enabled`);
}

const metadata = JSON.parse(run("cargo", ["metadata", "--format-version", "1", "--locked"]));
const vulnerableLibcrux = metadata.packages.filter(
  (item) =>
    item.name === "libcrux-chacha20poly1305" && !versionAtLeast(item.version, "0.0.8"),
);
if (vulnerableLibcrux.length > 0) {
  throw new Error("RUSTSEC-2026-0124 vulnerable libcrux-chacha20poly1305 remains in Cargo.lock");
}

process.stdout.write(
  `${JSON.stringify({
    ok: true,
    temporaryException: temporaryException.advisory,
    reachable: false,
    expiresOn: temporaryException.expiresOn,
    libcruxChacha20poly1305Minimum: "0.0.8",
  })}\n`,
);
