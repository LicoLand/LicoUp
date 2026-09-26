import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';

import { compileDartMachines, run } from '../compile-dart-machines.mjs';

const document = {
  dart: { output: 'lib/generated/sample.g.dart' },
  machines: [{
    id: 'sample.machine',
    states: [{ id: 'waiting' }, { id: 'in-progress', dart_name: 'inProgress' }, { id: 'done' }],
    events: ['start-work', 'finish'],
    initial: 'waiting',
    terminal: ['done'],
    transitions: [
      { from_state: 'waiting', event: 'start-work', to_state: 'in-progress' },
      { from_state: 'in-progress', event: 'finish', to_state: 'done' },
    ],
    dart: {
      state_enum: 'SampleState',
      event_enum: 'SampleEvent',
      transition_function: 'transitionSample',
      state_from_id_function: 'sampleStateFromId',
      event_for_transition_function: 'sampleEventForTransition',
    },
  }],
};

test('compiles typed Dart enums and transition targets from one config', () => {
  const result = compileDartMachines(document, 'state-machines.json');
  assert.equal(result.output, 'lib/generated/sample.g.dart');
  assert.match(result.content, /enum SampleState \{ waiting, inProgress, done \}/);
  assert.match(result.content, /enum SampleEvent \{ startWork, finish \}/);
  assert.match(result.content, /const SampleState sampleStateInitial = SampleState\.waiting;/);
  assert.match(result.content, /bool sampleStateIsTerminal\(SampleState state\)/);
  assert.match(result.content, /SampleState\.done => true/);
  assert.match(result.content, /\(SampleState\.waiting, SampleEvent\.startWork\) => SampleState\.inProgress/);
  assert.match(result.content, /_ => null/);
  assert.match(result.content, /SampleEvent\? sampleEventForTransition/);
  assert.match(result.content, /GENERATED CODE - DO NOT EDIT/);
});

test('initial and terminal declarations are executable generation inputs', () => {
  const changed = structuredClone(document);
  changed.machines[0].initial = 'in-progress';
  const result = compileDartMachines(changed, 'state-machines.json');
  assert.match(result.content, /const SampleState sampleStateInitial = SampleState\.inProgress;/);

  const escaping = structuredClone(document);
  escaping.machines[0].transitions.push({
    from_state: 'done',
    event: 'start-work',
    to_state: 'waiting',
  });
  assert.throws(
    () => compileDartMachines(escaping, 'state-machines.json'),
    /terminal state "done" has an outgoing transition/,
  );

  const selfLoop = structuredClone(document);
  selfLoop.machines[0].transitions.push({
    from_state: 'done',
    event: 'start-work',
    to_state: 'done',
  });
  assert.doesNotThrow(() => compileDartMachines(selfLoop, 'state-machines.json'));
});

test('refresh writes deterministically and check detects drift', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'lico-dart-machines-'));
  try {
    fs.writeFileSync(path.join(root, 'state-machines.json'), `${JSON.stringify(document)}\n`);
    run(['--config', 'state-machines.json', '--refresh'], { cwd: root });
    const output = path.join(root, document.dart.output);
    const first = fs.readFileSync(output, 'utf8');
    run(['--config', 'state-machines.json', '--check'], { cwd: root });
    run(['--config', 'state-machines.json', '--refresh'], { cwd: root });
    assert.equal(fs.readFileSync(output, 'utf8'), first);
    fs.appendFileSync(output, '// drift\n');
    assert.throws(
      () => run(['--config', 'state-machines.json', '--check'], { cwd: root }),
      /missing or stale/,
    );
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('rejects ambiguous transitions before emitting Dart', () => {
  const ambiguous = structuredClone(document);
  ambiguous.machines[0].transitions.push({
    from_state: 'waiting',
    event: 'start-work',
    to_state: 'done',
  });
  assert.throws(
    () => compileDartMachines(ambiguous, 'state-machines.json'),
    /ambiguous state\/event transitions/,
  );
});

test('can target a public enum emitted by another contract generator', () => {
  const external = structuredClone(document);
  external.dart.imports = ['package:example/contracts.g.dart'];
  external.machines[0].dart.emit_state_enum = false;
  const result = compileDartMachines(external, 'state-machines.json');
  assert.match(result.content, /import 'package:example\/contracts\.g\.dart';/);
  assert.doesNotMatch(result.content, /enum SampleState/);
  assert.match(result.content, /SampleState\? transitionSample/);
});
