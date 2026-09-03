#!/usr/bin/env node
import { entry, execute, workspace } from './adapter.mjs';
export async function gateReleasePolicy({ run = execute, cwd = workspace, env = process.env } = {}) {
  await run('npm', ['run', 'client:gate:release-policy'], { cwd, env });
}
await entry(import.meta.url, gateReleasePolicy);
