import { spawn } from 'node:child_process';
import { fileURLToPath, pathToFileURL } from 'node:url';
import path from 'node:path';
export const workspace = fileURLToPath(new URL('../../../', import.meta.url));
export async function execute(program, args, { cwd, env }) {
  await new Promise((resolve, reject) => {
    const child = spawn(program, args, { cwd, env, shell: false, stdio: 'ignore' });
    child.once('error', () => reject(new Error('adapter_child_failed')));
    child.once('exit', code => code === 0 ? resolve() : reject(new Error('adapter_child_failed')));
  });
}
export async function entry(url, run) {
  if (!process.argv[1] || pathToFileURL(path.resolve(process.argv[1])).href !== url) return;
  try { await run(); console.log(JSON.stringify({ ok: true, privateDataIncluded: false })); }
  catch { console.error(JSON.stringify({ ok: false, code: 'adapter_failed', privateDataIncluded: false })); process.exitCode = 1; }
}
