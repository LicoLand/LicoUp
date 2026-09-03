#!/usr/bin/env node
import { execFile } from 'node:child_process';
import { createReadStream } from 'node:fs';
import { mkdtemp, readFile, writeFile, rm, stat } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { promisify } from 'node:util';
import { pathToFileURL } from 'node:url';

const exec = promisify(execFile);
const fail = code => { throw Object.assign(new Error(code), { code }); };
export async function execute(program, args, options = {}) {
  const { allowFailure = false, ...rest } = options;
  try {
    const result = await exec(program, args, { ...rest, encoding: 'utf8', maxBuffer: 1024 * 1024 });
    return allowFailure ? { ok: true, output: result.stdout.trim() } : result.stdout.trim();
  } catch (error) {
    if (allowFailure) return { ok: false, output: String(error.stderr || '') };
    fail('source_command_failed');
  }
}
export function acceptedPromotion(event, eventName) {
  const pr = event?.pull_request;
  const repository = event?.repository?.full_name;
  if (eventName !== 'pull_request' || event?.action !== 'closed' || pr?.merged !== true ||
      pr?.base?.ref !== 'release' || pr?.head?.ref !== 'stable' ||
      !repository || pr?.head?.repo?.full_name !== repository || pr?.base?.repo?.full_name !== repository ||
      !/^[a-f0-9]{40}$/u.test(pr.merge_commit_sha || '') || !/^[a-f0-9]{40}$/u.test(pr.head.sha || '')) {
    fail('source_event_rejected');
  }
  return { repository, revision: pr.merge_commit_sha, head: pr.head.sha };
}
async function digest(file) {
  const hash = createHash('sha256');
  for await (const chunk of createReadStream(file)) hash.update(chunk);
  return hash.digest('hex');
}
export async function publishSource({ event, eventName, cwd = process.cwd(), run = execute }) {
  const { repository, revision, head } = acceptedPromotion(event, eventName);
  const git = args => run('git', args, { cwd });
  if (await git(['rev-parse', 'HEAD']) !== revision) fail('source_checkout_mismatch');
  const parents = (await git(['show', '-s', '--format=%P', revision])).split(/\s+/u);
  if (parents.length !== 2 || parents[1] !== head) fail('source_parent_mismatch');
  const document = JSON.parse(await git(['show', `${revision}:tools/client-version.json`]));
  const version = document.productVersion;
  if (!/^\d+\.\d+\.\d+$/u.test(version || '') || !Number.isSafeInteger(document.buildNumber) || document.buildNumber < 1) fail('source_version_invalid');
  const tag = `v${version}`, title = `LicoUp ${version}`, marker = `apple-release-source:v1:${revision}`;
  const archive = `LicoUp-source-${tag}.tar.gz`, checksum = `${archive}.sha256`;
  const gh = args => run('gh', args, { cwd });
  const observe = async endpoint => {
    const response = await run('gh', ['api', endpoint], { cwd, allowFailure: true });
    if (response.ok) return JSON.parse(response.output);
    if (/\(HTTP 404\)/u.test(response.output)) return null;
    fail('source_remote_ambiguous');
  };
  const [tagState, releaseState] = await Promise.all([
    observe(`repos/${repository}/git/ref/tags/${tag}`), observe(`repos/${repository}/releases/tags/${tag}`),
  ]);
  const remoteTag = tagState?.object?.sha;
  if (tagState && remoteTag !== revision) fail('source_tag_conflict');
  let release = releaseState;
  if (release && (!remoteTag || release.tag_name !== tag || release.name !== title || release.body !== marker ||
      release.prerelease !== false || typeof release.draft !== 'boolean')) fail('source_release_conflict');
  if (!remoteTag) {
    const tip = await observe(`repos/${repository}/git/ref/heads/release`);
    if (tip?.object?.sha !== revision) fail('source_release_tip_moved');
  }
  const root = await mkdtemp(path.join(tmpdir(), 'source-release-'));
  try {
    const file = path.join(root, archive);
    await git(['archive', '--format=tar.gz', `--prefix=LicoUp-${version}/`, `--output=${file}`, revision]);
    const expectedDigest = await digest(file);
    await writeFile(path.join(root, checksum), `${expectedDigest}  ${archive}\n`);
    if (!remoteTag) await gh(['api', '--method', 'POST', `repos/${repository}/git/refs`, '-f', `ref=refs/tags/${tag}`, '-f', `sha=${revision}`]);
    if (!release) {
      release = JSON.parse(await gh(['api', '--method', 'POST', `repos/${repository}/releases`, '-f', `tag_name=${tag}`, '-f', `name=${title}`, '-f', `body=${marker}`, '-F', 'draft=true', '-F', 'prerelease=false']));

    }
    const assets = JSON.parse(await gh(['api', `repos/${repository}/releases/${release.id}/assets?per_page=100`]));
    const allowed = new Set([archive, checksum, 'LicoUp-macos-arm64.dmg', 'LicoUp-macos-arm64.dmg.sha256', 'LicoUp-macos-arm64-update.zip', 'LicoUp-macos-arm64-update.zip.sha256', 'LicoUp-update-manifest.json']);
    if (!Array.isArray(assets) || new Set(assets.map(a => a.name)).size !== assets.length || assets.some(a => !allowed.has(a.name))) fail('source_asset_conflict');
    const downloaded = path.join(root, 'download');
    const { mkdir } = await import('node:fs/promises');
    await mkdir(downloaded);
    const verify = async name => {
      await gh(['release', 'download', tag, '--pattern', name, '--dir', downloaded, '--repo', repository]);
      if ((await stat(path.join(downloaded, name))).size <= 0 || await digest(path.join(downloaded, name)) !== await digest(path.join(root, name))) fail('source_asset_conflict');
    };
    // Validate every existing immutable asset before completing a partial draft.
    for (const name of [archive, checksum]) {
      if (assets.some(a => a.name === name)) await verify(name);
      else if (!release.draft) fail('source_public_asset_missing');
    }
    for (const name of [archive, checksum]) {
      if (assets.some(a => a.name === name)) continue;
      await gh(['release', 'upload', tag, path.join(root, name), '--repo', repository]);
      await verify(name);
    }
    if (release.draft) await gh(['api', '--method', 'PATCH', `repos/${repository}/releases/${release.id}`, '-F', 'draft=false']);
    const published = await observe(`repos/${repository}/releases/tags/${tag}`);
    if (published?.draft !== false || published?.prerelease !== false || published?.tag_name !== tag ||
        published?.name !== title || published?.body !== marker) fail('source_publication_unverified');
    return { ok: true, sourcePublished: true, privateDataIncluded: false };
  } finally { await rm(root, { recursive: true, force: true }); }
}
if (process.argv[1] && pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url) {
  try { console.log(JSON.stringify(await publishSource({ event: JSON.parse(await readFile(process.env.GITHUB_EVENT_PATH, 'utf8')), eventName: process.env.GITHUB_EVENT_NAME }))); }
  catch (error) { console.error(JSON.stringify({ ok: false, code: /^source_[a-z_]+$/u.test(error?.code || '') ? error.code : 'source_publication_failed', privateDataIncluded: false })); process.exitCode = 1; }
}
