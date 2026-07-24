import {
  existsSync,
  mkdirSync,
  statSync,
  writeFileSync,
} from "node:fs";
import path from "node:path";

import { sha256File } from "../../../../tools/scripts/lib/client-release-artifact-digest.mjs";
import { inspectWindowsPeFile } from "../../../../tools/scripts/lib/windows-pe-facts.mjs";
import {
  packageClientSchemas,
  packageFailure,
} from "./cli-policy.mjs";
import { relativeBundlePath } from "./portable-manifest.mjs";
import { flutterExecutableForRoot } from "./resource-assembly.mjs";

export function writeWindowsPlatformManifest(root, options, kind) {
  if (options.platform !== "windows") return "";
  const flutterExecutable = flutterExecutableForRoot(root, options.platform);
  const licoClientExecutable = path.join(root, "licoup.exe");
  assertExistingFile(flutterExecutable, "windows_flutter_executable_missing");
  assertExistingFile(licoClientExecutable, "windows_sidecar_missing");
  const manifestPath = path.join(
    root,
    "package-metadata",
    "windows",
    "client-manifest.json",
  );
  mkdirSync(path.dirname(manifestPath), { recursive: true });
  const manifest = {
    schemaVersion: packageClientSchemas.windowsPlatformManifest,
    generatedAt: new Date().toISOString(),
    platform: "windows",
    targetId: options.targetId,
    architecture: "x64",
    sourceStateDigest: options.releaseSourceStateDigest,
    mode: options.mode,
    kind,
    executables: {
      flutterClient: relativeBundlePath(root, flutterExecutable),
      licoClient: relativeBundlePath(root, licoClientExecutable),
    },
    launch: {
      gui: relativeBundlePath(root, flutterExecutable),
      cli: relativeBundlePath(root, licoClientExecutable),
    },
    artifacts: {
      flutterClient: artifactRecord(root, flutterExecutable),
      licoClient: artifactRecord(root, licoClientExecutable),
    },
  };
  writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`, "utf8");
  return manifestPath;
}

function artifactRecord(root, executable) {
  return {
    ref: relativeBundlePath(root, executable),
    sha256: sha256File(executable),
    pe: inspectWindowsPeFile(executable),
  };
}

function assertExistingFile(filePath, code) {
  if (!existsSync(filePath) || !statSync(filePath).isFile()) {
    packageFailure(code);
  }
}
