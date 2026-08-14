import assert from "node:assert/strict";
import fs from "node:fs/promises";
import fsSync from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../..");
const manifestPath = "schemas/client_bridge/manifest.json";
const generatorPath = "tools/scripts/generate-client-bridge-contracts.mjs";
const packagePath = "package.json";

const canonicalFamilies = [
  {
    id: "client_error",
    status: "active",
    schema: "schemas/client_bridge/client_error.schema.json",
    rustOutput: "crates/licoup-native/src/ffi/generated/client_error.rs",
    dartOutput: "apps/desktop/lib/src/contracts/generated/client_error.g.dart",
  },
  {
    id: "state",
    status: "active",
    schema: "schemas/client_bridge/state.json",
    rustOutput: "crates/licoup-native/src/ffi/generated/client_state.rs",
    dartOutput: "apps/desktop/lib/src/contracts/generated/client_state.g.dart",
  },
  {
    id: "secure_mesh",
    status: "active",
    schema: "schemas/client_bridge/secure_mesh.json",
    rustOutput: "crates/licoup-native/src/ffi/generated/secure_mesh.rs",
    dartOutput: "apps/desktop/lib/src/contracts/generated/secure_mesh.g.dart",
  },
  {
    id: "conversation",
    status: "active",
    schema: "schemas/client_bridge/conversation.json",
    rustOutput: "crates/licoup-native/src/ffi/generated/conversation.rs",
    dartOutput: "apps/desktop/lib/src/contracts/generated/conversation.g.dart",
  },
  {
    id: "strategy",
    status: "active",
    schema: "schemas/client_bridge/strategy.json",
    rustOutput: "crates/licoup-native/src/ffi/generated/strategy.rs",
    dartOutput: "apps/desktop/lib/src/contracts/generated/strategy.g.dart",
  },
  {
    id: "adapter_plugin",
    status: "planned",
    schema: "schemas/client_bridge/adapter_plugin.json",
    rustOutput: "crates/licoup-native/src/ffi/generated/adapter_plugin.rs",
    dartOutput: "apps/desktop/lib/src/contracts/generated/adapter_plugin.g.dart",
  },
  {
    id: "agent_usage",
    status: "planned",
    schema: "schemas/client_bridge/agent_usage.json",
    rustOutput: "crates/licoup-native/src/ffi/generated/agent_usage.rs",
    dartOutput: "apps/desktop/lib/src/contracts/generated/agent_usage.g.dart",
  },
];

const canonicalScripts = {
  "client:contracts:generate": "node tools/scripts/generate-client-bridge-contracts.mjs",
  "client:contracts:check": "node tools/scripts/generate-client-bridge-contracts.mjs --check",
};

function readJsonFrom(baseRoot, relativePath) {
  return fs.readFile(path.join(baseRoot, relativePath), "utf8").then(JSON.parse);
}

async function readTextFrom(baseRoot, relativePath) {
  return fs.readFile(path.join(baseRoot, relativePath), "utf8");
}

function isSafeRepoRelative(value) {
  if (typeof value !== "string") {
    return false;
  }
  if (path.isAbsolute(value)) {
    return false;
  }
  const normalized = path.normalize(value);
  if (normalized.startsWith(".." + path.sep) || normalized === ".." || /\.{2}[\\/]/u.test(normalized)) {
    return false;
  }
  return true;
}

function assertSafeUniqueManifest(manifest) {
  const seenSchema = new Set();
  const seenRust = new Set();
  const seenDart = new Set();

  for (const family of manifest.families) {
    assert.equal(isSafeRepoRelative(family.schema), true);
    assert.equal(isSafeRepoRelative(family.rustOutput), true);
    assert.equal(isSafeRepoRelative(family.dartOutput), true);

    assert.equal(seenSchema.has(family.schema), false, `duplicate schema path: ${family.schema}`);
    assert.equal(seenRust.has(family.rustOutput), false, `duplicate rust path: ${family.rustOutput}`);
    assert.equal(seenDart.has(family.dartOutput), false, `duplicate dart path: ${family.dartOutput}`);

    seenSchema.add(family.schema);
    seenRust.add(family.rustOutput);
    seenDart.add(family.dartOutput);
  }
}

function copyRepoSubset(root, destination) {
  const manifest = JSON.parse(fsSync.readFileSync(path.join(root, manifestPath), "utf8"));
  const targets = new Set([
    manifestPath,
    generatorPath,
    packagePath,
    "tools/templates/client_bridge",
    ...manifest.families.flatMap((family) => [
      family.schema,
      family.rustOutput,
      family.dartOutput,
    ]),
  ]);

  for (const relativePath of targets) {
    const source = path.join(root, relativePath);
    if (!fsSync.existsSync(source)) {
      continue;
    }
    const target = path.join(destination, relativePath);
    fsSync.mkdirSync(path.dirname(target), { recursive: true });
    fsSync.cpSync(source, target, { force: true, recursive: true, preserveTimestamps: false });
  }
}

function makeScratch(root) {
  const destination = fsSync.mkdtempSync(path.join(os.tmpdir(), "lico-bridge-gen-"));
  copyRepoSubset(root, destination);
  return destination;
}

function runGenerator(repo, args = []) {
  return spawnSync(process.execPath, ["./" + generatorPath, ...args], {
    cwd: repo,
    encoding: "utf8",
  });
}

function diagnostic(result) {
  return result.stderr || result.stdout || "";
}

function failWithPattern(label, args, regex) {
  assert.notEqual(args.status, 0, `${label} must fail`);
  const output = diagnostic(args);
  assert.match(output, regex, `${label}: ${output}`);
}

test("1) exact ordered manifest entries and unique safe contract schema/output paths", async () => {
  const manifest = await readJsonFrom(repoRoot, manifestPath);
  assert.equal(manifest.version, 1);
  assert.equal(Array.isArray(manifest.families), true);

  const expectedOrder = canonicalFamilies.map((family) => family.id);
  assert.deepEqual(
    manifest.families.map((family) => family.id),
    expectedOrder,
    "manifest order must be client_error -> state -> secure_mesh -> conversation -> strategy -> adapter_plugin -> agent_usage",
  );

  const expectedMap = new Map(canonicalFamilies.map((family) => [family.id, family]));
  for (let i = 0; i < canonicalFamilies.length; i += 1) {
    const manifestFamily = manifest.families[i];
    const expectedFamily = expectedMap.get(manifestFamily.id);
    assert.ok(expectedFamily, `unexpected family id ${manifestFamily.id}`);
    assert.equal(manifestFamily.status, expectedFamily.status);
    assert.equal(manifestFamily.schema, expectedFamily.schema);
    assert.equal(manifestFamily.rustOutput, expectedFamily.rustOutput);
    assert.equal(manifestFamily.dartOutput, expectedFamily.dartOutput);
    assert.equal(manifest.families[i].status, canonicalFamilies[i].status);
  }

  assertSafeUniqueManifest(manifest);
});

test("2) package scripts canonicalize generation and generator is manifest-driven without single-family hardcoding", async () => {
  const packageJson = await readJsonFrom(repoRoot, packagePath);
  for (const [name, command] of Object.entries(canonicalScripts)) {
    assert.equal(packageJson.scripts[name], command);
  }

  const generatorSource = await readTextFrom(repoRoot, generatorPath);
  assert.ok(generatorSource.includes(manifestPath));
  assert.match(generatorSource, /--check/);
  assert.ok(/manifest\.families/.test(generatorSource) || /families\s*=/.test(generatorSource));
  assert.equal(
    /schemas\/client_bridge\/client_error\.schema\.json/.test(generatorSource),
    false,
    "cannot hardcode only client_error schema",
  );
  assert.equal(
    /crates\/licoup-native\/src\/ffi\/generated\/client_error\.rs/.test(generatorSource),
    false,
    "cannot hardcode only client_error rust output",
  );
  assert.equal(
    /apps\/desktop\/lib\/src\/contracts\/generated\/client_error\.g\.dart/.test(generatorSource),
    false,
    "cannot hardcode only client_error dart output",
  );
});

test("conversation schema, generator expectation, and generated action set stay explicit", async () => {
  const schema = JSON.parse(
    await readTextFrom(repoRoot, "schemas/client_bridge/conversation.json"),
  );
  const generator = await readTextFrom(repoRoot, generatorPath);
  const dartBinding = await readTextFrom(
    repoRoot,
    "apps/desktop/lib/src/contracts/generated/conversation.g.dart",
  );
  const rustBinding = await readTextFrom(
    repoRoot,
    "crates/licoup-native/src/ffi/generated/conversation.rs",
  );
  const retired = ["conversation.default-local-group", "sync"].join(".");
  const retiredPattern = new RegExp(retired.replaceAll(".", "\\."), "u");
  assert.equal(schema.actions.includes(retired), false, retired);
  assert.doesNotMatch(generator, retiredPattern, `${retired} in generator`);
  assert.doesNotMatch(dartBinding, retiredPattern, `${retired} in Dart binding`);
  assert.doesNotMatch(rustBinding, retiredPattern, `${retired} in Rust binding`);
  for (const action of schema.actions) {
    const pattern = new RegExp(action.replaceAll(".", "\\."), "u");
    assert.match(generator, pattern, `generator missing ${action}`);
    assert.match(dartBinding, pattern, `Dart binding missing ${action}`);
    assert.match(rustBinding, pattern, `Rust binding missing ${action}`);
  }
});

test("3) --check must keep tracked mtimes and content unchanged while planned outputs stay absent", async () => {
  const scratch = makeScratch(repoRoot);
  const manifest = await readJsonFrom(scratch, manifestPath);

  const tracked = new Map();
  for (const family of manifest.families) {
    for (const target of [family.schema, family.rustOutput, family.dartOutput]) {
      const absolute = path.join(scratch, target);
      if (fsSync.existsSync(absolute)) {
        tracked.set(target, {
          content: await readTextFrom(scratch, target),
          mtimeMs: fsSync.statSync(absolute).mtimeMs,
        });
      }
    }
  }

  const check = runGenerator(scratch, ["--check"]);
  assert.equal(check.status, 0, `check must pass\n${diagnostic(check)}`);

  for (const [target, before] of tracked) {
    const absolute = path.join(scratch, target);
    assert.equal(
      fsSync.statSync(absolute).mtimeMs,
      before.mtimeMs,
      `mtime changed for ${target}`,
    );
    assert.equal(
      await readTextFrom(scratch, target),
      before.content,
      `content changed for ${target}`,
    );
  }

  for (const family of manifest.families) {
    const rustOutput = path.join(scratch, family.rustOutput);
    const dartOutput = path.join(scratch, family.dartOutput);
    if (family.status === "planned") {
      assert.equal(fsSync.existsSync(rustOutput), false);
      assert.equal(fsSync.existsSync(dartOutput), false);
    } else {
      assert.equal(fsSync.existsSync(rustOutput), true);
      assert.equal(fsSync.existsSync(dartOutput), true);
    }
  }
});

test("4) manifest mutation and tracked artifacts produce bounded failures in check mode", async () => {
  const base = makeScratch(repoRoot);
  const manifest = await readJsonFrom(base, manifestPath);
  const active = manifest.families[0];

  // duplicate id
  {
    const mutated = makeScratch(base);
    const payload = await readJsonFrom(mutated, manifestPath);
    payload.families[1].id = payload.families[0].id;
    await fs.writeFile(path.join(mutated, manifestPath), JSON.stringify(payload), "utf8");
    failWithPattern(
      "duplicate family id",
      runGenerator(mutated, ["--check"]),
      /duplicate|conflict|id/i,
    );
  }

  // unsafe path
  {
    const mutated = makeScratch(base);
    const payload = await readJsonFrom(mutated, manifestPath);
    payload.families[2].schema = "../outside.schema.json";
    await fs.writeFile(path.join(mutated, manifestPath), JSON.stringify(payload), "utf8");
    failWithPattern(
      "unsafe schema path",
      runGenerator(mutated, ["--check"]),
      /unsafe|traversal|outside|path/i,
    );
  }

  // stale/hand-edited output
  {
    const mutated = makeScratch(base);
    const generated = await readTextFrom(mutated, active.rustOutput);
    await fs.writeFile(path.join(mutated, active.rustOutput), `${generated}\n// hand edited`, "utf8");
    failWithPattern(
      "hand edited output",
      runGenerator(mutated, ["--check"]),
      /stale generated output/,
    );
  }

  // unregistered generated file
  {
    const mutated = makeScratch(base);
    const strayRust = path.join(mutated, "crates/licoup-native/src/ffi/generated/stray.rs");
    const strayDart = path.join(mutated, "apps/desktop/lib/src/contracts/generated/stray.g.dart");
    fsSync.mkdirSync(path.dirname(strayRust), { recursive: true });
    fsSync.mkdirSync(path.dirname(strayDart), { recursive: true });
    await fs.writeFile(strayRust, "// stray", "utf8");
    await fs.writeFile(strayDart, "// stray", "utf8");
    failWithPattern(
      "unregistered outputs",
      runGenerator(mutated, ["--check"]),
      /unregistered|unexpected|orphan|extra|stray/i,
    );
  }

  // missing active schema
  {
    const mutated = makeScratch(base);
    await fs.unlink(path.join(mutated, active.schema));
    failWithPattern(
      "missing active schema",
      runGenerator(mutated, ["--check"]),
      /missing|not found|ENOENT|open|read/i,
    );
  }

  // missing active output
  {
    const mutated = makeScratch(base);
    await fs.unlink(path.join(mutated, active.rustOutput));
    failWithPattern(
      "missing active output",
      runGenerator(mutated, ["--check"]),
      /missing|not found|ENOENT|open|write/i,
    );
  }
});
