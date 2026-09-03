#!/usr/bin/env node
import { entry, execute, workspace } from './adapter.mjs';
export async function gateSource({ run = execute, cwd = workspace, env = process.env } = {}) {
  await run('npm', ['run', 'client:gate:source'], { cwd, env });
}
await entry(import.meta.url, gateSource);
