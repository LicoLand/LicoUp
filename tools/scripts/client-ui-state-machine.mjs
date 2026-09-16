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
const model = JSON.parse(readFileSync(path.join(root, 'docs/functionality/UI-INTERACTIONS.json'), 'utf8'));
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
  const rows = ['# 界面状态转换结果', '',
    profile ? '真实引擎 profile；按用户操作统计。' : '本机 widget 功能检查；虚拟时间不计作性能。', '',
    `随机种子：${report.seed}；每个流程追加 ${report.randomSteps} 次随机操作。`, '',
    '| 流程 | 已走过的不同转换 / 模型声明 | 执行结果 |', '| --- | --- | --- |'];
  for (const id of machines) {
    const covered = new Set((report.results ?? []).filter((row) => row.machine === id && row.passed).map((row) => row.transition)).size;
    rows.push(`| ${model.machines.find((machine) => machine.id === id)?.label ?? id} | ${covered} / ${report.declaredTransitions[id]} | ${report.completedMachines?.[id] ? '完成' : id in (report.completedMachines ?? {}) ? '失败' : '未运行'} |`);
  }
  const number = (value) => typeof value === 'number' ? value.toFixed(1) : '—';
  rows.push('', '## 操作汇总', '', '| 做什么 | 成功 / 执行次数 | 通常响应 ms（中位数） | 最慢响应 ms | 采到的帧数 | 长帧数 |', '| --- | --- | --- | --- | --- | --- |');
  const byAction = Map.groupBy(report.results ?? [], (row) => row.actionId);
  for (const actionRows of byAction.values()) {
    const times = actionRows.flatMap((row) => typeof row.responseMs === 'number' ? [row.responseMs] : []).sort((a, b) => a - b);
    const middle = Math.floor(times.length / 2);
    const median = times.length ? (times[middle] + times[Math.floor((times.length - 1) / 2)]) / 2 : undefined;
    const sampled = actionRows.filter((row) => row.frameCount > 0);
    rows.push(`| ${escape(actionRows[0].action)} | ${actionRows.filter((row) => row.passed).length} / ${actionRows.length} | ${number(median)} | ${number(times.at(-1))} | ${sampled.length ? sampled.reduce((sum, row) => sum + row.frameCount, 0) : '—'} | ${sampled.length ? sampled.reduce((sum, row) => sum + (row.overBudgetFrames ?? 0), 0) : '—'} |`);
  }
  rows.push('', `完整的起点、动作、目标、逐次耗时、帧率与帧耗时见 [操作记录](${basename}.json)。`, '');
  const details = (report.results ?? []).filter((row) => !row.passed);
  if (profile) details.push(...(report.results ?? []).filter((row) => row.passed).sort((a, b) => b.responseMs - a.responseMs).slice(0, 10));
  if (details.length) {
    rows.push('## 失败步骤与最慢操作', '', '| 界面 / 步骤 | 从哪里 | 做什么 | 应到哪里 | 结果 | 响应 ms | 帧率 | 长帧数 |', '| --- | --- | --- | --- | --- | --- | --- | --- |');
    for (const row of details) rows.push(`| ${row.presentation} / ${row.step} ${row.phase} | ${escape(row.from)} | ${escape(row.action)} | ${escape(row.to)} | ${row.passed ? '通过' : '失败'} | ${number(row.responseMs)} | ${number(row.renderedFramesPerSecond)} | ${row.overBudgetFrames ?? '—'} |`);
  }
  rows.push('', '## 失败重放', '');
  const profileReplay = profile ? ` --profile --device ${['macos', 'linux', 'windows'].includes(device) ? device : '<local-target>'}` : '';
  for (const [id, failure] of Object.entries(report.failures ?? {})) {
    const actions = failure.replay.length ? `--replay ${failure.replay.join(',')}` : '--steps 0';
    rows.push(`- ${id}: \`npm run client:test:ui -- --machine ${id} --seed ${seed}${profileReplay} ${actions}\``);
  }
  rows.push('', '## 可见操作遗漏', '', '下面列出已访问界面中，当前状态尚未声明转换的按钮；全部已声明转换通过并不等于整个产品已经覆盖。无文字按钮也会列出，需补充语义名称或人工核对。完整位置保存在操作记录中。', '', '| 可见操作 | 已知动作 | 缺少转换的状态数 | 例如 |', '| --- | --- | --- | --- |');
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
  for (const { control, states } of omissions.values()) rows.push(`| ${escape(control.label)} | ${control.actions.map((action) => model.actions[action]?.label ?? action).join(', ') || '未映射'} | ${states.length} | ${escape(states.slice(0, 2).join('；'))} |`);
  rows.push('', '响应耗时包含测试驱动开销。拖动耗时包括手势持续时间。长帧表示界面计算或绘制用时超过当前显示器的一帧间隔；原始帧耗时在 JSON 中。单帧操作不计算帧率；空闲界面不要求持续满帧。缺采样显示“—”。', '');
  writeFileSync(markdown, rows.join('\n'));
  console.log(`Report: ${path.relative(root, markdown)}`);
} else console.error('No UI report was produced; this run does not establish coverage.');
process.exitCode = child.status === 0 && complete ? 0 : child.status || 1;
