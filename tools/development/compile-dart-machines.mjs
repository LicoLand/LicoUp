#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const DART_KEYWORDS = new Set([
  'abstract', 'as', 'assert', 'async', 'await', 'base', 'break', 'case',
  'catch', 'class', 'const', 'continue', 'covariant', 'default', 'deferred',
  'do', 'dynamic', 'else', 'enum', 'export', 'extends', 'extension',
  'external', 'factory', 'false', 'final', 'finally', 'for', 'Function',
  'get', 'hide', 'if', 'implements', 'import', 'in', 'interface', 'is',
  'late', 'library', 'mixin', 'new', 'null', 'of', 'on', 'operator', 'part',
  'required', 'rethrow', 'return', 'sealed', 'set', 'show', 'static',
  'super', 'switch', 'sync', 'this', 'throw', 'true', 'try', 'typedef',
  'var', 'void', 'when', 'while', 'with', 'yield',
]);

function fail(message) {
  throw new Error(`Dart state-machine generation: ${message}`);
}

function lowerCamel(value) {
  const pieces = String(value).trim().split(/[^A-Za-z0-9]+/).filter(Boolean);
  if (pieces.length === 0) fail(`cannot derive a Dart identifier from ${JSON.stringify(value)}`);
  const [first, ...rest] = pieces;
  return first.slice(0, 1).toLowerCase() + first.slice(1) + rest
    .map((piece) => piece.slice(0, 1).toUpperCase() + piece.slice(1))
    .join('');
}

function dartIdentifier(value, label) {
  const identifier = String(value ?? '').trim();
  if (!/^[A-Za-z_$][A-Za-z0-9_$]*$/.test(identifier) || DART_KEYWORDS.has(identifier)) {
    fail(`${label} is not a usable Dart identifier: ${JSON.stringify(value)}`);
  }
  return identifier;
}

function quoted(value) {
  return `'${String(value).replaceAll('\\', '\\\\').replaceAll("'", "\\'")}'`;
}

function requireArray(value, label) {
  if (!Array.isArray(value)) fail(`${label} must be an array`);
  return value;
}

function machineSource(machine, index) {
  const id = String(machine?.id ?? '').trim();
  if (!id) fail(`machines[${index}].id is required`);
  const dart = machine.dart;
  if (!dart || typeof dart !== 'object' || Array.isArray(dart)) {
    fail(`${id}.dart generation metadata is required`);
  }
  const stateEnum = dartIdentifier(dart.state_enum, `${id}.dart.state_enum`);
  const eventEnum = dartIdentifier(dart.event_enum, `${id}.dart.event_enum`);
  const transitionFunction = dartIdentifier(
    dart.transition_function,
    `${id}.dart.transition_function`,
  );
  const stateFromIdFunction = dartIdentifier(
    dart.state_from_id_function,
    `${id}.dart.state_from_id_function`,
  );
  const stateIdFunction = dartIdentifier(
    dart.state_id_function ?? `${stateEnum.slice(0, 1).toLowerCase()}${stateEnum.slice(1)}Id`,
    `${id}.dart.state_id_function`,
  );
  const eventIdFunction = dartIdentifier(
    dart.event_id_function ?? `${eventEnum.slice(0, 1).toLowerCase()}${eventEnum.slice(1)}Id`,
    `${id}.dart.event_id_function`,
  );
  const eventFromIdFunction = dartIdentifier(
    dart.event_from_id_function ?? `${eventEnum.slice(0, 1).toLowerCase()}${eventEnum.slice(1)}FromId`,
    `${id}.dart.event_from_id_function`,
  );
  const eventForTransitionFunction = dart.event_for_transition_function == null
    ? null
    : dartIdentifier(
      dart.event_for_transition_function,
      `${id}.dart.event_for_transition_function`,
    );
  const statePrefix = `${stateEnum.slice(0, 1).toLowerCase()}${stateEnum.slice(1)}`;
  const initialConstant = dartIdentifier(
    dart.initial_constant ?? `${statePrefix}Initial`,
    `${id}.dart.initial_constant`,
  );
  const terminalFunction = dartIdentifier(
    dart.terminal_function ?? `${statePrefix}IsTerminal`,
    `${id}.dart.terminal_function`,
  );

  const states = requireArray(machine.states, `${id}.states`).map((state, stateIndex) => {
    const stateId = String(state?.id ?? '').trim();
    if (!stateId) fail(`${id}.states[${stateIndex}].id is required`);
    return {
      id: stateId,
      name: dartIdentifier(state.dart_name ?? lowerCamel(stateId), `${id} state ${stateId}`),
    };
  });
  const events = requireArray(machine.events, `${id}.events`).map((event, eventIndex) => {
    const eventId = String(event).trim();
    if (!eventId) fail(`${id}.events[${eventIndex}] must be non-empty`);
    return { id: eventId, name: dartIdentifier(lowerCamel(eventId), `${id} event ${eventId}`) };
  });
  if (states.length === 0) fail(`${id}.states must not be empty`);
  if (events.length === 0) fail(`${id}.events must not be empty`);
  for (const [label, values] of [['state id', states.map((v) => v.id)], ['normalized state id', states.map((v) => v.id.toLowerCase())], ['state name', states.map((v) => v.name)], ['event id', events.map((v) => v.id)], ['normalized event id', events.map((v) => v.id.toLowerCase())], ['event name', events.map((v) => v.name)]]) {
    if (new Set(values).size !== values.length) fail(`${id} has duplicate ${label}s`);
  }
  const statesById = new Map(states.map((state) => [state.id, state]));
  const eventsById = new Map(events.map((event) => [event.id, event]));
  const initialId = String(machine.initial ?? '').trim();
  if (!statesById.has(initialId)) {
    fail(`${id}.initial names an unknown state ${JSON.stringify(initialId)}`);
  }
  const terminalIds = requireArray(machine.terminal, `${id}.terminal`).map((value, terminalIndex) => {
    const terminalId = String(value ?? '').trim();
    if (!statesById.has(terminalId)) {
      fail(`${id}.terminal[${terminalIndex}] names an unknown state ${JSON.stringify(terminalId)}`);
    }
    return terminalId;
  });
  if (new Set(terminalIds).size !== terminalIds.length) fail(`${id} has duplicate terminal states`);
  const terminalIdSet = new Set(terminalIds);
  const transitions = requireArray(machine.transitions, `${id}.transitions`).map((transition, transitionIndex) => {
    const from = String(transition?.from_state ?? '').trim();
    const event = String(transition?.event ?? '').trim();
    const to = String(transition?.to_state ?? '').trim();
    if (!statesById.has(from)) fail(`${id}.transitions[${transitionIndex}] has unknown from_state ${JSON.stringify(from)}`);
    if (!eventsById.has(event)) fail(`${id}.transitions[${transitionIndex}] has unknown event ${JSON.stringify(event)}`);
    if (!statesById.has(to)) fail(`${id}.transitions[${transitionIndex}] has unknown to_state ${JSON.stringify(to)}`);
    return { from: statesById.get(from), event: eventsById.get(event), to: statesById.get(to) };
  });
  const keys = transitions.map((transition) => `${transition.from.id}\0${transition.event.id}`);
  if (new Set(keys).size !== keys.length) fail(`${id} has ambiguous state/event transitions`);
  const terminalEscape = transitions.find(
    (transition) => terminalIdSet.has(transition.from.id) && transition.to.id !== transition.from.id,
  );
  if (terminalEscape != null) {
    fail(`${id} terminal state ${JSON.stringify(terminalEscape.from.id)} has an outgoing transition`);
  }

  const stateCases = states.map((state) => `    ${stateEnum}.${state.name} => ${quoted(state.id)},`).join('\n');
  const fromIdCases = states.map((state) => `    ${quoted(state.id.toLowerCase())} => ${stateEnum}.${state.name},`).join('\n');
  const eventCases = events.map((event) => `    ${eventEnum}.${event.name} => ${quoted(event.id)},`).join('\n');
  const eventFromIdCases = events.map((event) => `    ${quoted(event.id.toLowerCase())} => ${eventEnum}.${event.name},`).join('\n');
  const transitionCases = transitions.map((transition) =>
    `    (${stateEnum}.${transition.from.name}, ${eventEnum}.${transition.event.name}) => ${stateEnum}.${transition.to.name},`
  ).join('\n');
  const reverseCases = transitions.map((transition) =>
    `    (${stateEnum}.${transition.from.name}, ${stateEnum}.${transition.to.name}) => ${eventEnum}.${transition.event.name},`
  ).join('\n');

  const lines = [
    ...(dart.emit_state_enum === false
      ? []
      : [`enum ${stateEnum} { ${states.map((state) => state.name).join(', ')} }`, '']),
    `enum ${eventEnum} { ${events.map((event) => event.name).join(', ')} }`,
    '',
    `const ${stateEnum} ${initialConstant} = ${stateEnum}.${statesById.get(initialId).name};`,
    '',
    `bool ${terminalFunction}(${stateEnum} state) => switch (state) {`,
    ...terminalIds.map((terminalId) => `    ${stateEnum}.${statesById.get(terminalId).name} => true,`),
    ...(terminalIds.length === states.length ? [] : ['    _ => false,']),
    '  };',
    '',
    `String ${stateIdFunction}(${stateEnum} state) => switch (state) {`,
    stateCases,
    '  };',
    '',
    `${stateEnum}? ${stateFromIdFunction}(String id) => switch (id.trim().toLowerCase()) {`,
    fromIdCases,
    '    _ => null,',
    '  };',
    '',
    `String ${eventIdFunction}(${eventEnum} event) => switch (event) {`,
    eventCases,
    '  };',
    '',
    `${eventEnum}? ${eventFromIdFunction}(String id) => switch (id.trim().toLowerCase()) {`,
    eventFromIdCases,
    '    _ => null,',
    '  };',
    '',
    `${stateEnum}? ${transitionFunction}(${stateEnum} state, ${eventEnum} event) =>`,
    '    switch ((state, event)) {',
    transitionCases,
    ...(transitions.length === states.length * events.length ? [] : ['      _ => null,']),
    '    };',
  ];
  if (eventForTransitionFunction != null) {
    const reverseKeys = transitions.map((transition) => `${transition.from.id}\0${transition.to.id}`);
    if (new Set(reverseKeys).size !== reverseKeys.length) {
      fail(`${id} cannot generate an event-for-transition function for ambiguous state targets`);
    }
    lines.push(
      '',
      `${eventEnum}? ${eventForTransitionFunction}(${stateEnum} state, ${stateEnum} target) =>`,
      '    switch ((state, target)) {',
      reverseCases,
      '      _ => null,',
      '    };',
    );
  }
  return lines.join('\n');
}

export function compileDartMachines(document, sourcePath) {
  if (!document || typeof document !== 'object' || Array.isArray(document)) fail('configuration root must be an object');
  const output = String(document.dart?.output ?? '').trim();
  if (!output) fail('root dart.output is required');
  const machines = requireArray(document.machines, 'machines');
  if (machines.length === 0) fail('machines must not be empty');
  const imports = document.dart.imports == null
    ? []
    : requireArray(document.dart.imports, 'dart.imports').map((value, index) => {
      const imported = String(value).trim();
      if (!/^package:[A-Za-z0-9_./-]+\.dart$/u.test(imported)) {
        fail(`dart.imports[${index}] is not a package Dart import`);
      }
      return imported;
    });
  if (new Set(imports).size !== imports.length) fail('dart.imports contains duplicates');
  if (
    machines.some((machine) => machine?.dart?.emit_state_enum === false) &&
    imports.length === 0
  ) {
    fail('dart.imports is required when a state enum is emitted elsewhere');
  }
  const bodies = machines.map(machineSource);
  const unformatted = [
    '// GENERATED CODE - DO NOT EDIT.',
    `// Source: ${sourcePath.replaceAll('\\', '/')}`,
    '// Refresh with tools/development/compile-dart-machines.mjs.',
    '',
    ...imports.map((value) => `import '${value}';`),
    ...(imports.length === 0 ? [] : ['']),
    ...bodies.flatMap((body, index) => index === 0 ? [body] : ['', body]),
    '',
  ].join('\n');
  const formatted = spawnSync('dart', ['format'], {
    input: unformatted,
    encoding: 'utf8',
    maxBuffer: 16 * 1024 * 1024,
  });
  if (formatted.error != null) fail(`cannot run dart format: ${formatted.error.message}`);
  if (formatted.status !== 0) fail(`dart format failed: ${formatted.stderr.trim()}`);
  return {
    output,
    content: formatted.stdout,
  };
}

function parseArgs(argv) {
  let config = '';
  let mode = 'check';
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--config') config = argv[++index] ?? '';
    else if (arg === '--check') mode = 'check';
    else if (arg === '--refresh') mode = 'refresh';
    else fail(`unknown argument ${arg}`);
  }
  if (!config) fail('--config <path> is required');
  return { config, mode };
}

export function run(argv, { cwd = process.cwd() } = {}) {
  const { config, mode } = parseArgs(argv);
  const configPath = path.resolve(cwd, config);
  const sourcePath = path.relative(cwd, configPath).replaceAll('\\', '/');
  const document = JSON.parse(fs.readFileSync(configPath, 'utf8'));
  const generated = compileDartMachines(document, sourcePath);
  const outputPath = path.resolve(cwd, generated.output);
  if (mode === 'refresh') {
    fs.mkdirSync(path.dirname(outputPath), { recursive: true });
    fs.writeFileSync(outputPath, generated.content);
    process.stdout.write(`refreshed ${path.relative(cwd, outputPath)}\n`);
    return;
  }
  const actual = fs.existsSync(outputPath) ? fs.readFileSync(outputPath, 'utf8') : '';
  if (actual !== generated.content) {
    fail(`${path.relative(cwd, outputPath)} is missing or stale; run with --refresh`);
  }
  process.stdout.write(`current ${path.relative(cwd, outputPath)}\n`);
}

const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : '';
if (invokedPath === fileURLToPath(import.meta.url)) {
  try {
    run(process.argv.slice(2));
  } catch (error) {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  }
}
