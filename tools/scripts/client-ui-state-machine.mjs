#!/usr/bin/env node
import { spawnSync } from 'node:child_process';
import { readFileSync, writeFileSync, mkdirSync, mkdtempSync, existsSync, rmSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const root = fileURLToPath(new URL('../..', import.meta.url));
const options = new Map();
const flags = new Set(['--profile', '--describe']);
const values = new Set(['--device', '--seed', '--steps', '--machine', '--replay']);
const args = process.argv.slice(2);
for (let i = 0; i < args.length; i++) {
  const name = args[i];
  if (flags.has(name)) options.set(name, true);
  else if (values.has(name) && args[i + 1] && !args[i + 1].startsWith('--')) options.set(name, args[++i]);
  else throw new Error(`Unknown option or missing value: ${name}`);
}
const profile = options.has('--profile');
const device = options.get('--device');
const seed = options.get('--seed') ?? String(Date.now() >>> 0);
const steps = options.get('--steps') ?? '40';
const machineId = options.get('--machine') ?? '';
const replay = options.get('--replay') ?? '';
for (const [name, value] of [['seed', seed], ['steps', steps]]) {
  if (!/^\d+$/.test(value) || !Number.isSafeInteger(Number(value)) || Number(value) > 0xffffffff) throw new Error(`Invalid ${name}: use an integer from 0 to 4294967295.`);
}
const model = JSON.parse(readFileSync(path.join(root, 'apps/desktop/test/ui_state_machine/model.json'), 'utf8'));
if (machineId && !model.machines.some((machine) => machine.id === machineId)) throw new Error('Unknown UI flow. Use --describe.');
if (replay && !machineId) throw new Error('Replay requires --machine and a comma-separated action sequence.');
if (profile && machineId && !model.machines.find((machine) => machine.id === machineId).presentation.endsWith('-wide')) throw new Error('This flow is available in widget mode; profile currently runs desktop views.');
if (options.has('--describe')) {
  for (const machine of model.machines.filter((item) => !machineId || item.id === machineId)) {
    console.log(`${machine.label} [${machine.id}; ${machine.presentation}]`);
    const labels = new Map(machine.states.map((state) => [state.id, state.label]));
    for (const edge of machine.transitions) console.log(`  ${labels.get(edge.from_state)} → ${model.actions[edge.action].label} → ${labels.get(edge.to_state)}`);
  }
  process.exit(0);
}
if (profile && !device) throw new Error('Choose an already available local target: --profile --device macos');
console.log(`UI exploration seed: ${seed}; random actions per flow: ${steps}`);
const command = profile
  ? ['drive', '--profile', '--driver=test_driver/ui_state_machine.dart', '--target=integration_test/ui_state_machine_test.dart', '-d', device]
  : ['test', 'test/ui_state_machine', '--reporter', 'expanded'];
const reportDirectory = path.join(root, 'build/reports/ui-state-machine');
const defineParent = path.join(root, 'build/tmp/ui-state-machine');
mkdirSync(reportDirectory, { recursive: true });
mkdirSync(defineParent, { recursive: true });
const defineDirectory = mkdtempSync(path.join(defineParent, 'run-'));
const defines = path.join(defineDirectory, 'defines.json');
const profileConfig = path.join(defineDirectory, 'profile.xcconfig');
const environment = { ...process.env };
if (profile && device === 'macos') {
  // The synthetic test is a separate application, so the production single-
  // instance policy cannot redirect it to an open personal-data instance.
  writeFileSync(profileConfig, `${environment.XCODE_XCCONFIG_FILE ? `#include ${JSON.stringify(environment.XCODE_XCCONFIG_FILE)}\n` : ''}PRODUCT_BUNDLE_IDENTIFIER = land.lico.licoup.ui-interactions\n`);
  environment.XCODE_XCCONFIG_FILE = profileConfig;
}
writeFileSync(defines, JSON.stringify({
  LICO_UI_MODEL: Buffer.from(JSON.stringify(model)).toString('base64'),
  LICO_UI_SEED: seed, LICO_UI_STEPS: steps, LICO_UI_MACHINE: machineId, LICO_UI_REPLAY: replay,
  // flutter drive collects results over the VM service, not XCTest.
  ...(profile ? { INTEGRATION_TEST_SHOULD_REPORT_RESULTS_TO_NATIVE: 'false' } : {}),
}));
const basename = profile ? 'profile' : 'widget';
const reportPath = path.join(reportDirectory, `${basename}.json`);
const markdown = path.join(reportDirectory, `${basename}.md`);
rmSync(reportPath, { force: true });
rmSync(markdown, { force: true });
let child;
try {
  child = spawnSync(process.execPath, [
    'tools/scripts/client-toolchain-runner.mjs', '--check', 'flutter', '--cwd', 'apps/desktop', '--',
    'flutter', ...command, `--dart-define-from-file=${path.relative(path.join(root, 'apps/desktop'), defines)}`,
  ], { cwd: root, stdio: 'inherit', env: environment });
} finally {
  rmSync(defineDirectory, { recursive: true, force: true });
}
let complete = false;
if (existsSync(reportPath)) {
  const report = JSON.parse(readFileSync(reportPath, 'utf8'));
  const machines = Object.keys(report.declaredTransitions ?? {});
  complete = machines.length > 0 && machines.every((id) => report.completedMachines?.[id]);
  const escape = (value) => String(value ?? '').replaceAll('|', '\\|').replaceAll('\n', ' ');
  const rows = ['# Interface state-transition results', '',
    profile ? 'Real-engine profile; counted per user operation.' : 'On-machine widget functional check; virtual time is not treated as performance.', '',
    `Random seed: ${report.seed}; each flow appends ${report.randomSteps} random operations.`, '',
    '| Flow | Distinct transitions walked / declared by the model | Result |', '| --- | --- | --- |'];
  for (const id of machines) {
    const covered = new Set((report.results ?? []).filter((row) => row.machine === id && row.passed).map((row) => row.transition)).size;
    rows.push(`| ${model.machines.find((machine) => machine.id === id)?.label ?? id} | ${covered} / ${report.declaredTransitions[id]} | ${report.completedMachines?.[id] ? 'passed' : id in (report.completedMachines ?? {}) ? 'failed' : 'not run'} |`);
  }
  const number = (value) => typeof value === 'number' ? value.toFixed(1) : '—';
  rows.push('', '## Operation summary', '', '| Action | Succeeded / executions | Typical response ms (median) | Slowest response ms | Frames sampled | Long frames |', '| --- | --- | --- | --- | --- | --- |');
  const byAction = Map.groupBy(report.results ?? [], (row) => row.actionId);
  for (const actionRows of byAction.values()) {
    const times = actionRows.flatMap((row) => typeof row.responseMs === 'number' ? [row.responseMs] : []).sort((a, b) => a - b);
    const middle = Math.floor(times.length / 2);
    const median = times.length ? (times[middle] + times[Math.floor((times.length - 1) / 2)]) / 2 : undefined;
    const sampled = actionRows.filter((row) => row.frameCount > 0);
    rows.push(`| ${escape(actionRows[0].action)} | ${actionRows.filter((row) => row.passed).length} / ${actionRows.length} | ${number(median)} | ${number(times.at(-1))} | ${sampled.length ? sampled.reduce((sum, row) => sum + row.frameCount, 0) : '—'} | ${sampled.length ? sampled.reduce((sum, row) => sum + (row.overBudgetFrames ?? 0), 0) : '—'} |`);
  }
  rows.push('', `Full origins, actions, targets, per-run timings, frame rates and frame costs are in the [operation record](${basename}.json).`, '');
  const details = (report.results ?? []).filter((row) => !row.passed);
  if (profile) details.push(...(report.results ?? []).filter((row) => row.passed).sort((a, b) => b.responseMs - a.responseMs).slice(0, 10));
  if (details.length) {
    rows.push('## Failed steps and slowest operations', '', '| Interface / step | From | Action | Expected | Result | Response ms | Frame rate | Long frames |', '| --- | --- | --- | --- | --- | --- | --- | --- |');
    for (const row of details) rows.push(`| ${row.presentation} / ${row.step} ${row.phase} | ${escape(row.from)} | ${escape(row.action)} | ${escape(row.to)} | ${row.passed ? 'passed' : 'failed'} | ${number(row.responseMs)} | ${number(row.renderedFramesPerSecond)} | ${row.overBudgetFrames ?? '—'} |`);
  }
  rows.push('', '## Failure replay', '');
  const profileReplay = profile ? ` --profile --device ${['macos', 'linux', 'windows'].includes(device) ? device : '<local-target>'}` : '';
  for (const [id, failure] of Object.entries(report.failures ?? {})) {
    const actions = failure.replay.length ? `--replay ${failure.replay.join(',')}` : '--steps 0';
    rows.push(`- ${id}: \`npm run client:test:ui -- --machine ${id} --seed ${seed}${profileReplay} ${actions}\``);
  }
  rows.push('', '## Visible-operation omissions', '', 'The list below names buttons in visited interfaces whose current state declares no transition; every declared transition passing does not mean the whole product is covered. Buttons without text are listed too and need a semantic name or a manual check. Full locations are kept in the operation record.', '', '| Visible control | Known actions | States missing a transition | Example |', '| --- | --- | --- | --- |');
  const omissions = new Map();
  for (const [state, controls] of Object.entries(report.visibleControls ?? {})) {
    const [flowId, stateId] = state.split('/');
    const flow = model.machines.find((item) => item.id === flowId);
    const label = flow?.states.find((item) => item.id === stateId)?.label ?? stateId;
    const seen = new Set();
    for (const control of controls.filter((item) => !item.coveredHere)) {
      const signature = `${control.label}/${control.actions.join(',')}`;
      if (seen.has(signature)) continue;
      seen.add(signature);
      const item = omissions.get(signature) ?? { control, states: [] };
      item.states.push(label);
      omissions.set(signature, item);
    }
  }
  for (const { control, states } of omissions.values()) rows.push(`| ${escape(control.label)} | ${control.actions.map((action) => model.actions[action]?.label ?? action).join(', ') || 'unmapped'} | ${states.length} | ${escape(states.slice(0, 2).join('; '))} |`);
  rows.push('', 'Response time includes test-driver overhead. Drag time includes the gesture duration. A long frame means interface computation or painting took longer than one refresh interval of the current display; raw frame costs are in the JSON. A single-frame operation has no frame rate, and an idle interface is not required to sustain full frame rate. A missing sample shows "none".', '');
  writeFileSync(markdown, rows.join('\n'));
  console.log(`Report: ${path.relative(root, markdown)}`);
} else console.error('No UI report was produced; this run does not establish coverage.');
process.exitCode = child.status === 0 && complete ? 0 : child.status || 1;
