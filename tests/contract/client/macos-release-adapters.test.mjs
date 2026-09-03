import assert from 'node:assert/strict';
import test from 'node:test';
import { readFile } from 'node:fs/promises';
import { gateSource } from '../../../tools/scripts/macos-release/gate-source.mjs';
import { gateReleasePolicy } from '../../../tools/scripts/macos-release/gate-release-policy.mjs';
import { build } from '../../../tools/scripts/macos-release/build.mjs';
import { writeUpdateManifest } from '../../../tools/scripts/macos-release/write-update-manifest.mjs';
const document = JSON.parse(await readFile('tools/client-version.json'));
const argv = ['--tag', `v${document.productVersion}`, '--repository', 'LicoLand/LicoUp', '--version', document.productVersion];
test('four adapters delegate once and force stable build track', async () => {
  const calls = [], run = async (...args) => calls.push(args);
  await gateSource({ run }); await gateReleasePolicy({ run });
  await build({ run, env: { LICO_CLIENT_RELEASE_TRACK: 'nightly' } });
  await writeUpdateManifest({ run, argv, env: { LICO_UPDATE_OFFLINE_ROOT_KEY: 'synthetic', LICO_UPDATE_ONLINE_SIGNING_KEY: 'synthetic' } });
  assert.deepEqual(calls.slice(0, 3).map(call => call[1]), [
    ['run', 'client:gate:source'], ['run', 'client:gate:release-policy'], ['run', 'client:build', '--', '--platform', 'macos']]);
  assert.equal(calls[2][2].env.LICO_CLIENT_RELEASE_TRACK, 'stable');
  assert.ok(calls.every(call => call[2].cwd === process.cwd() || call[2].cwd === `${process.cwd()}/`));
  assert.deepEqual(calls[3][1], ['tools/scripts/client-update-manifest.mjs', '--assets', 'build/apple-release',
    '--tag', `v${document.productVersion}`, '--repo', 'LicoLand/LicoUp', '--targets', 'macos-direct-arm64',
    '--release-track', 'stable', '--minimum-supported-version', '0.0.0']);
});
test('adapters propagate first failure and reject mismatched source or key names', async () => {
  let calls = 0; const run = async () => { calls++; throw new Error('synthetic failure'); };
  for (const adapter of [gateSource, gateReleasePolicy, build]) await assert.rejects(adapter({ run }));
  assert.equal(calls, 3);
  await assert.rejects(writeUpdateManifest({ argv: [...argv.slice(0, 5), '9.9.9'], run }));
  await assert.rejects(writeUpdateManifest({ argv, run, env: { LICO_UPDATE_OFFLINE_ROOT_KEY: 'synthetic', UNRELATED_KEY: 'synthetic' } }));
  assert.equal(calls, 3);
});
