#!/usr/bin/env node
import { entry, execute, workspace } from './adapter.mjs';
export async function build({ run = execute, cwd = workspace, env = process.env } = {}) {
  await run('npm', ['run', 'client:build', '--', '--platform', 'macos'], {
    cwd, env: { ...env, LICO_CLIENT_RELEASE_TRACK: 'stable' },
  });
}
await entry(import.meta.url, build);
