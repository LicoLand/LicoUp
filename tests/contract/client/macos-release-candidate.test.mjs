import assert from 'node:assert/strict';
import test from 'node:test';
import { readFileSync } from 'node:fs';
import { evaluateBranchFlow, verifyCandidatePush, LONG_LIVED_BRANCHES } from '../../../tools/scripts/verify-branch-flow.mjs';
const revision = 'a'.repeat(40);
test('candidate creation and resume require exact release SHA and tree', () => {
  assert.deepEqual(LONG_LIVED_BRANCHES, ['nightly', 'stable', 'release']);
  assert.equal(evaluateBranchFlow({ eventName: 'push', refName: 'macos-release-candidate', payload: { before: '0'.repeat(40) } }).ok, true);
  assert.equal(verifyCandidatePush({ after: revision, releaseRevision: revision, candidateTree: () => 'tree' }).ok, true);
  for (const after of ['', '0'.repeat(40), 'b'.repeat(40)]) assert.equal(verifyCandidatePush({ after, releaseRevision: revision }).ok, false);
  assert.equal(verifyCandidatePush({ after: revision, releaseRevision: revision, deleted: true }).ok, false);
  const payload = { repository: { full_name: 'example/repo' }, pull_request: { head: { repo: { full_name: 'example/repo' } } } };
  for (const baseRef of LONG_LIVED_BRANCHES) assert.equal(evaluateBranchFlow({ eventName: 'pull_request', baseRef, headRef: 'macos-release-candidate', payload }).ok, false);
});
test('four unchanged checks admit only the fixed candidate, preserving trusted PR handling', () => {
  for (const [file, name] of [['branch-flow','Branch flow'], ['commit-identity','Commit identity'], ['lico-auditor-gate','Auditor'], ['client-release-ready','Release ready']]) {
    const value = readFileSync(`.github/workflows/${file}.yml`, 'utf8');
    assert.match(value, /macos-release-candidate/u); assert.ok(value.includes(`name: ${name}`));
    assert.match(value, /github.event.deleted != true/u);
  }
  const identity = readFileSync('.github/workflows/commit-identity.yml','utf8');
  assert.match(identity, /pull_request_target:/u); assert.doesNotMatch(identity, /actions\/checkout/u);
  assert.match(identity, /verification.verified == true/u); assert.match(identity, /verification.reason == "valid"/u);
  assert.match(identity, /jq '\[\[\.\]\]'/u);
  const ready = readFileSync('.github/workflows/client-release-ready.yml','utf8');
  assert.match(ready, /if: github.event_name == 'pull_request'\n        id: readme/u);
  assert.match(ready, /verify-branch-flow.mjs/u); assert.doesNotMatch(ready, /client:build|GH_TOKEN|secrets\./u);
});
