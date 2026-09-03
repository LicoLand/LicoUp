#!/usr/bin/env node
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { entry, execute, workspace } from './adapter.mjs';
export async function writeUpdateManifest({ argv = process.argv.slice(2), run = execute, cwd = workspace, env = process.env } = {}) {
  if (argv.length !== 6 || argv[0] !== '--tag' || argv[2] !== '--repository' || argv[4] !== '--version') throw new Error('adapter_arguments_invalid');
  const [, tag, , repository, , version] = argv;
  const document = JSON.parse(await readFile(path.join(cwd, 'tools/client-version.json'), 'utf8'));
  if (version !== document.productVersion || tag !== `v${version}` || repository !== 'LicoLand/LicoUp' ||
      !env.LICO_UPDATE_OFFLINE_ROOT_KEY || !env.LICO_UPDATE_ONLINE_SIGNING_KEY) throw new Error('adapter_contract_invalid');
  await run(process.execPath, ['tools/scripts/client-update-manifest.mjs', '--assets', 'build/apple-release',
    '--tag', tag, '--repo', repository, '--targets', 'macos-direct-arm64', '--release-track', 'stable',
    '--minimum-supported-version', '0.0.0'], { cwd, env });
}
await entry(import.meta.url, writeUpdateManifest);
