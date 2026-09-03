import assert from 'node:assert/strict';
import test from 'node:test';
import { mkdtemp, mkdir, writeFile, readFile, copyFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { acceptedPromotion, execute, publishSource } from '../../../tools/scripts/client-source-release.mjs';
async function fixture(t) {
  const root = await mkdtemp(path.join(tmpdir(), 'source-fixture-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const git = args => execute('git', args, { cwd: root, env: { ...process.env, GIT_CONFIG_GLOBAL: '/dev/null', GIT_CONFIG_NOSYSTEM: '1' } });
  await git(['init', '-q', '-b', 'release']);
  await git(['config', 'user.name', 'Release Fixture']); await git(['config', 'user.email', 'fixture@example.invalid']);
  await mkdir(path.join(root, 'tools')); await writeFile(path.join(root, 'tools/client-version.json'), JSON.stringify({ productVersion: '0.1.1', buildNumber: 2 }));
  await git(['add', '.']); await git(['commit', '-qm', 'fixture base']);
  await git(['checkout', '-qb', 'stable']); await writeFile(path.join(root, 'source.txt'), 'accepted source\n');
  await git(['add', '.']); await git(['commit', '-qm', 'fixture source']); const head = await git(['rev-parse','HEAD']);
  await git(['checkout', '-q', 'release']); await git(['merge','--no-ff','-qm','fixture promotion','stable']);
  const revision = await git(['rev-parse','HEAD']);
  const repository = { full_name: 'LicoLand/LicoUp' };
  const event = { action: 'closed', repository, pull_request: { merged: true, merge_commit_sha: revision,
    head: { ref: 'stable', sha: head, repo: repository }, base: { ref: 'release', repo: repository } } };
  const state = { tag: null, release: null, assets: new Map(), writes: [] };
  const run = async (program, args, options) => {
    if (program === 'git') return git(args);
    assert.equal(program, 'gh');
    if (options.allowFailure) {
      let value;
      if (args[1].endsWith('/git/ref/tags/v0.1.1')) value = state.tag && { object: { sha: state.tag } };
      else if (args[1].endsWith('/releases/tags/v0.1.1')) value = state.release;
      else if (args[1].endsWith('/git/ref/heads/release')) value = { object: { sha: revision } };
      else assert.fail('unexpected read');
      return value ? { ok: true, output: JSON.stringify(value) } : { ok: false, output: '(HTTP 404)' };
    }
    if (args[0] === 'api' && args[1].endsWith('/assets?per_page=100')) return JSON.stringify([...state.assets.keys()].map(name => ({ name, size: 1 })));
    if (args[0] === 'api' && args[1] === '--method') {
      state.writes.push(args[2] + ':' + args[3].split('/').at(-1));
      if (args[2] === 'POST' && args[3].endsWith('/git/refs')) { assert.equal(state.tag, null); state.tag = revision; return '{}'; }
      if (args[2] === 'POST' && args[3].endsWith('/releases')) {
        assert.equal(state.release, null); state.release = { id: 1, tag_name: 'v0.1.1', name: 'LicoUp 0.1.1', body: `apple-release-source:v1:${revision}`, draft: true, prerelease: false }; return JSON.stringify(state.release);
      }
      if (args[2] === 'PATCH' && args[3].endsWith('/releases/1')) { state.release.draft = false; return '{}'; }
      assert.fail('unexpected mutation');
    }
    if (args[0] === 'release' && args[1] === 'upload') {
      const name = path.basename(args[3]); assert.equal(state.assets.has(name), false); assert.equal(state.release.draft, true);
      state.assets.set(name, await readFile(args[3])); state.writes.push(`upload:${name}`); return '';
    }
    if (args[0] === 'release' && args[1] === 'download') {
      await writeFile(path.join(args[args.indexOf('--dir') + 1], args[args.indexOf('--pattern') + 1]), state.assets.get(args[args.indexOf('--pattern') + 1])); return '';
    }
    assert.fail('unexpected operation');
  };
  return { root, event, state, run, publish: () => publishSource({ event, eventName: 'pull_request', cwd: root, run }) };
}
test('accepted exact merge creates source pair and public retry preserves platform assets', async t => {
  const f = await fixture(t); assert.equal((await f.publish()).ok, true); assert.equal(f.state.assets.size, 2);
  for (const name of ['LicoUp-macos-arm64.dmg','LicoUp-macos-arm64.dmg.sha256','LicoUp-macos-arm64-update.zip','LicoUp-macos-arm64-update.zip.sha256','LicoUp-update-manifest.json']) f.state.assets.set(name, Buffer.from('synthetic'));
  f.state.writes = []; await f.publish(); assert.deepEqual(f.state.writes, []); assert.equal(f.state.assets.size, 7);
});
test('partial exact draft completes without replacing present assets', async t => {
  const f = await fixture(t); await f.publish(); f.state.release.draft = true;
  f.state.assets.delete('LicoUp-source-v0.1.1.tar.gz.sha256'); f.state.writes = [];
  await f.publish(); assert.deepEqual(f.state.writes, ['upload:LicoUp-source-v0.1.1.tar.gz.sha256','PATCH:1']);
});
test('rejected events and wrong parent cannot mutate', async t => {
  const f = await fixture(t);
  for (const change of [event => { event.pull_request.merged = false; }, event => { event.pull_request.head.ref = 'nightly'; },
    event => { event.pull_request.head.repo = { full_name: 'fork/repository' }; }, event => { event.pull_request.head.sha = 'a'.repeat(40); }]) {
    const event = structuredClone(f.event); change(event);
    await assert.rejects(publishSource({ event, eventName: 'pull_request', cwd: f.root, run: f.run }));
  }
  assert.throws(() => acceptedPromotion(f.event, 'push')); assert.deepEqual(f.state.writes, []);
});
test('public source/tag/metadata conflicts are immutable failures', async t => {
  const f = await fixture(t); await f.publish(); f.state.writes = [];
  f.state.tag = 'f'.repeat(40); await assert.rejects(f.publish(), { code: 'source_tag_conflict' });
  f.state.tag = f.event.pull_request.merge_commit_sha; f.state.release.body = 'foreign';
  await assert.rejects(f.publish(), { code: 'source_release_conflict' });
  f.state.release.body = `apple-release-source:v1:${f.state.tag}`;
  f.state.assets.set('LicoUp-source-v0.1.1.tar.gz', Buffer.from('foreign source'));
  await assert.rejects(f.publish(), { code: 'source_asset_conflict' });
  f.state.assets.delete('LicoUp-source-v0.1.1.tar.gz');
  await assert.rejects(f.publish(), { code: 'source_public_asset_missing' });
  assert.deepEqual(f.state.writes, []);
});
