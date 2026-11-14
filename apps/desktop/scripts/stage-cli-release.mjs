#!/usr/bin/env node
// Stages the pinned LicoUp-CLI release into build/native-artifacts/<platform>
// for development builds (`flutter run`, `npm run client:run:macos`). Packaging
// performs the same stage itself.
//
//   node apps/desktop/scripts/stage-cli-release.mjs [--archive <path>]
//
// `--archive` names a local release archive (for example one produced in a
// LicoUp-CLI checkout); it runs every contract check and skips only the pinned
// digest, which the printed record reports.
import process from "node:process";

import {
  normalizePlatform,
  publicPackageFailure,
  publicWorkspacePath,
} from "./package-client/cli-policy.mjs";
import { nativeArtifactsDirectory } from "./package-client/build/native.mjs";
import {
  CLI_RELEASE_ARCHIVE_ENV,
  stageCliRelease,
} from "./package-client/cli-release/stage.mjs";

function parseArguments(argv) {
  const environment = { ...process.env };
  for (let index = 0; index < argv.length; index += 1) {
    if (argv[index] === "--archive" && argv[index + 1]) {
      environment[CLI_RELEASE_ARCHIVE_ENV] = argv[index + 1];
      index += 1;
    } else {
      throw new Error(`unknown argument: ${argv[index]}`);
    }
  }
  return environment;
}

try {
  const environment = parseArguments(process.argv.slice(2));
  const platform = normalizePlatform(process.platform);
  const stagingDirectory = nativeArtifactsDirectory({ platform }, environment);
  const release = stageCliRelease({ platform, stagingDirectory, environment });
  console.log(JSON.stringify({
    ok: true,
    ...release,
    stagingRef: publicWorkspacePath(stagingDirectory),
    privatePathsIncluded: false,
  }, null, 2));
} catch (error) {
  console.error(JSON.stringify(publicPackageFailure(error), null, 2));
  process.exitCode = 1;
}
