import { spawnSync } from "node:child_process";

// RustSec advisory exceptions and duplicate-generation governance for the
// client dependency gate.
//
// Advisory exceptions: the only accepted form is a TEMPORARY exception bound
// to an `expiresOn` date. The gate hard-fails once an expiry date has passed,
// so exceptions are always removed or re-audited, never silently extended.
//
// Current state: RUSTSEC-2026-0173 (proc-macro-error2, unmaintained) is
// RESOLVED. Upstream hax is still at 0.3.7 on crates.io (which vendors
// proc-macro-error2 with no patched version), but hax removed the dependency
// in upstream commit 8f9cb576e58f6cc7e9ed249a7d4439b0f7ed0da7, and root
// Cargo.toml patches `hax-lib` (source `^0.3.7`, used by libcrux-ml-kem
// 0.0.10 / libcrux-sha3 0.0.10 / libcrux-intrinsics 0.0.8) to that pinned
// git revision. proc-macro-error2 is no longer reachable in the product
// graph, so no advisory exception remains.

const TEMPORARY_EXCEPTIONS = Object.freeze([]);

// Duplicate-generation governance.
//
// `cargo tree -d` on the production graph (`-e no-dev`, `--locked`) must stay
// under DUPLICATE_CRATE_CEILING and every duplicate crate name must be listed
// here with the transitive pin that forces it. This makes the residual
// duplicates an explicit, reviewed set instead of silent drift.
//
// The audit target is DUPLICATE_CRATE_TARGET (≤15). The remaining 28 are
// forced by fixed protocol inputs or by an upstream generation split this
// repository must not force-break:
//   - the openmls git revision (34222ef6..., RustCrypto 0.10 / dalek 2
//     generation: aes-gcm 0.10, chacha20poly1305 0.10, p256 0.13, p384 0.13,
//     x25519-dalek 2, ed25519-dalek 2, rand_core 0.6, rand_chacha 0.3) sits
//     against the fixed LicoArc SDK revision (244ce718..., L03.0, RustCrypto
//     0.11 / dalek 3 generation: aead 0.6, cipher 0.5, poly1305 0.9,
//     universal-hash 0.6, chacha20poly1305 0.11, ed25519-dalek 3,
//     x25519-dalek 3). Both revisions are fixed protocol inputs and the pin
//     cannot move: no upstream openmls revision exists on the 0.11
//     generation. hpke-rs is capped at 0.7.0 on crates.io, celabshq/libcrux
//     main still pins aes-gcm 0.10 / chacha20poly1305 0.10 / p256 0.13 /
//     x25519-dalek 2, and openmls main and v0.9.0 carry the same generations
//     as the pin. Every remaining RustCrypto/dalek duplicate below is a leaf
//     of that split.
//   - sha3 0.11 vs 0.12: x-wing 0.1.0 (newest release) depends on ml-kem
//     ^0.3 -> sha3 ^0.11 and on sha3 ^0.12 directly, and ml-kem 0.3.2 is the
//     newest release. This one is an upstream x-wing defect, not a consumer
//     choice.
//   - ureq 2.x -> webpki-roots 0.26.11 shim -> webpki-roots 1.x. ureq 3
//     dropped the custom-rustls-verifier hook that
//     domain/provider_quota/http.rs depends on, so the migration is deferred
//     rather than forced.
const TRACKED_DUPLICATE_GENERATIONS = Object.freeze({
  aead: "0.5.2 via aes-gcm 0.10.3 and chacha20poly1305 0.10.1 (openmls rev, direct) vs 0.6.1 via the fixed LicoArc SDK (chacha20poly1305 0.11.0)",
  "block-buffer": "digest 0.10 family (direct sha2 0.10/hkdf 0.12/hmac 0.12, ed25519-dalek 2, p256 via openmls rev) vs digest 0.11 family (x-wing via hpke-rs 0.7)",
  chacha20: "0.9.1 via chacha20poly1305 0.10.1 (openmls rev, direct) vs 0.10.2 via the fixed LicoArc SDK",
  chacha20poly1305: "0.10.1 direct licoup-native and openmls rev vs 0.11.0 via the fixed LicoArc SDK",
  cipher: "0.4.4 via aes/aes-gcm/ctr/chacha20 0.9 (openmls rev, direct) vs 0.5.2 via the fixed LicoArc SDK",
  "const-oid": "der 0.7 (p256 via openmls rev) vs der 0.8 (ml-dsa via openmls_basic_credential)",
  cpufeatures: "sha2 0.10 line vs curve25519-dalek 5/chacha20 0.10/keccak (libcrux 0.0.10 and x-wing via hpke-rs 0.7)",
  "crypto-common": "aead 0.5/aes-gcm 0.10 (openmls rev, chacha20poly1305 0.10) vs digest 0.11 line (libcrux, x-wing)",
  "curve25519-dalek": "ed25519-dalek 2/x25519-dalek 2 (direct, openmls rev) vs x25519-dalek 3 (x-wing via hpke-rs 0.7)",
  der: "ecdsa/p256 0.13 (openmls rev) vs pkcs8 0.11/ml-dsa (openmls_basic_credential)",
  digest: "sha2 0.10/ed25519-dalek 2/p256 family vs sha2 0.11 family (openmls_rust_crypto, x-wing)",
  ed25519: "2.2.3 via ed25519-dalek 2.2.0 (direct, openmls rev) vs 3.0.0 via the fixed LicoArc SDK",
  "ed25519-dalek": "2.2.0 direct licoup-native and openmls rev vs 3.0.0 via the fixed LicoArc SDK",
  getrandom: "rand_core 0.6 (ed25519-dalek 2, x25519-dalek 2, p256 via openmls rev) vs rand_core 0.10 (libcrux 0.0.10, x-wing)",
  hkdf: "0.12 direct + dbus-secret-service 4.1 + elliptic-curve (openmls rev) vs 0.13 (openmls_rust_crypto, ml-kem via hpke-rs)",
  hmac: "0.12 direct vs 0.13 (openmls_rust_crypto, hpke-rs line)",
  inout: "0.1.4 via cipher 0.4.4 (openmls rev, direct) vs 0.2.2 via the fixed LicoArc SDK",
  pkcs8: "ed25519-dalek 2/ecdsa 0.16 (openmls rev) vs ml-dsa (openmls_basic_credential)",
  poly1305: "0.8.0 via chacha20poly1305 0.10.1 (openmls rev, direct) vs 0.9.1 via the fixed LicoArc SDK",
  rand_chacha: "0.3.1 via openmls_rust_crypto (openmls rev) vs 0.10.0 via hpke-rs-rust-crypto 0.7.0 (openmls rev, experimental)",
  rand_core: "0.6 (ed25519-dalek 2, x25519-dalek 2, p256 via openmls rev) vs 0.10 (libcrux 0.0.10, x-wing)",
  sha2: "0.10 (direct, ed25519-dalek 2, p256, dbus-secret-service) vs 0.11 (openmls_rust_crypto, ml-dsa)",
  sha3: "0.11 (libcrux-sha3 0.0.10 via libcrux-ml-kem) vs 0.12 (x-wing via hpke-rs 0.7)",
  signature: "ed25519-dalek 2/ecdsa (openmls rev) vs ml-dsa/openmls_rust_crypto",
  spki: "ecdsa/ed25519 (openmls rev) vs ml-dsa/pkcs8 0.11",
  "universal-hash": "0.5.1 via chacha20poly1305 0.10.1 (openmls rev, direct) vs 0.6.1 via the fixed LicoArc SDK",
  "webpki-roots": "ureq 2.x pinned 0.26.11 alias (normal dep webpki-roots ^1); ureq 3 migration deferred (API + TLS stack change)",
  "x25519-dalek": "2.0.1 direct + hpke-rs-rust-crypto 0.7 vs 3.0.0 via x-wing (hpke-rs 0.7 experimental)",
});

const DUPLICATE_CRATE_TARGET = 15;
// The macOS and Linux production graphs now carry the same 28 duplicates,
// all of them the pinned crypto generations recorded above. That is down from
// 33: the unused `notify` dependency was dropped (Linux-only `bitflags`), and
// `jni` 0.21 -> 0.22 (`jni-sys` shim, `thiserror` 1) and the direct `rand` ->
// `rand_core` substitution (`rand`) each removed a duplicate generation.
const DUPLICATE_CRATE_CEILING = 28;

function run(command, args) {
  const result = spawnSync(command, args, {
    cwd: process.cwd(),
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
    maxBuffer: 32 * 1024 * 1024,
  });
  if (result.status !== 0) {
    throw new Error(`${command} failed while validating RustSec exceptions`);
  }
  return result.stdout || "";
}

function validateExpiry(exception) {
  const expiry = new Date(`${exception.expiresOn}T00:00:00Z`);
  if (!Number.isFinite(expiry.getTime()) || Date.now() >= expiry.getTime()) {
    throw new Error(`${exception.advisory} exception expired; remove or re-audit it`);
  }
}

function validateReachability(exception) {
  const metadata = JSON.parse(run("cargo", ["metadata", "--format-version", "1", "--locked"]));
  if (!metadata.packages.some((item) => item.name === exception.package)) {
    return;
  }
  const activeInverseTree = run("cargo", [
    "tree",
    "--workspace",
    "--locked",
    "-i",
    exception.package,
    "-e",
    "all",
  ]);
  if (activeInverseTree.includes(`${exception.package} v`)) {
    throw new Error(`${exception.advisory} became reachable in the product feature graph`);
  }
}

function validateDuplicateGenerations() {
  const tree = run("cargo", ["tree", "-d", "--workspace", "--locked", "-e", "no-dev"]);
  const versions = new Map();
  for (const line of tree.split(/\r?\n/u)) {
    const match = /^([a-z0-9_-]+) v([0-9][^ ]*)/u.exec(line);
    if (!match) continue;
    const set = versions.get(match[1]) ?? new Set();
    set.add(match[2]);
    versions.set(match[1], set);
  }
  const duplicateCrates = [...versions.entries()]
    .filter(([, set]) => set.size > 1)
    .map(([name]) => name)
    .sort();
  const unexplained = duplicateCrates.filter(
    (name) => !TRACKED_DUPLICATE_GENERATIONS[name],
  );
  if (duplicateCrates.length > DUPLICATE_CRATE_CEILING) {
    throw new Error(
      `duplicate crate generations rose above the ${DUPLICATE_CRATE_CEILING} ceiling: ${duplicateCrates.length}`,
    );
  }
  if (unexplained.length > 0) {
    throw new Error(
      `unexplained duplicate crate generations: ${unexplained.join(", ")}; ` +
        "converge them or record the pinned reason in TRACKED_DUPLICATE_GENERATIONS",
    );
  }
  return {
    duplicateCrates,
    tracked: duplicateCrates.length,
    target: DUPLICATE_CRATE_TARGET,
    ceiling: DUPLICATE_CRATE_CEILING,
  };
}

for (const exception of TEMPORARY_EXCEPTIONS) {
  validateExpiry(exception);
  validateReachability(exception);
}

const duplicateGovernance = validateDuplicateGenerations();

const rustCfg = run("rustc", ["--print", "cfg"]);
if (rustCfg.split(/\r?\n/u).some((line) => line.trim() === "hax")) {
  throw new Error("advisory exception contracts are invalid when cfg(hax) is enabled");
}

process.stdout.write(
  `${JSON.stringify({
    ok: true,
    temporaryException: TEMPORARY_EXCEPTIONS.length === 0
      ? null
      : TEMPORARY_EXCEPTIONS.map((exception) => exception.advisory),
    reachable: false,
    ...duplicateGovernance,
  })}\n`,
);
