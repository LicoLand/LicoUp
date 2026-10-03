import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

// The thirteen per-Agent parsers stay one inventory; the composition that names
// them, the shared adapter contract, the registry lookup, the replay harness and
// the lifecycle authority are split between the host, the adapter SDK and the
// Agent packages the moved parsers live in.
const parserRoot = 'crates/licoup-native/src/platform/native_agent_parser';
const compositionRoot = `${parserRoot}/adapters`;
const sdkRoot = 'crates/licoup-agent-adapter-sdk/src';
const adapters = [
  'antigravity',
  'claude_code',
  'codex',
  'copilot',
  'cursor',
  'hermes',
  'kilo_code',
  'kimi_code',
  'openclaw',
  'opencode',
  'pi',
  'lico_agent',
  'deepseek_harness',
];
// An Agent whose parser has moved carries its declaration in its own package, so
// the composition names the package and the component the check reads is the
// package's parser. The registration constructor each package uses is asserted
// where that package's registration now lives, because the owner changed and the
// answer has to be read from its owner.
const movedParsers = {
  codex: {
    crate: 'licoup_agent_codex',
    registration: 'crates/licoup-agent-codex/src/registration.rs',
    component: 'crates/licoup-agent-codex/src/parser.rs',
    constructor: /ParserRegistration::new\(/u,
    answers: ['execution_transitions', 'valid_identity'],
    // The client's own app-server process half reads this parser by name.
    alias: 'codex',
  },
  copilot: {
    crate: 'licoup_agent_copilot',
    registration: 'crates/licoup-agent-copilot/src/registration.rs',
    component: 'crates/licoup-agent-copilot/src/parser.rs',
    constructor: /ParserRegistration::unanswered\(/u,
    answers: [],
    // Nothing in the host reads this parser by name: the shared ACP engine reads
    // it through the dialect the package registers.
    alias: null,
  },
};
const movedCount = Object.keys(movedParsers).length;

test('packaged adapter registry is bijective with the thirteen-entry inventory', () => {
  const composition = readFileSync(`${compositionRoot}/mod.rs`, 'utf8');
  const registrations = composition.slice(
    composition.indexOf('pub(in crate::platform) static REGISTRATIONS'),
    composition.indexOf('/// The parser registrations this host injects'),
  );
  // Every entry names its Agent's declaration exactly once — locally or through
  // the package that owns it — and none inherits another Agent's answer.
  assert.equal(
    (registrations.match(/ParserRegistration::(?:unanswered|new)\(/g) ?? []).length + movedCount,
    13,
  );
  // The queries a reader reaches are answered by the Agent that owns the fact:
  // Hermes' normalized transitions, and the exact-resume identity of the four
  // Agents the Subagent mesh dispatches. Every other entry stays declared and
  // unanswered rather than inheriting a neighbouring Agent's answer.
  const answered = {
    antigravity: ['no_transitions', 'antigravity_identity'],
    claude_code: ['no_transitions', 'claude_code_identity'],
    codex: ['codex_transitions', 'codex_identity'],
    cursor: ['no_transitions', 'cursor_identity'],
    hermes: ['hermes_transitions', 'no_identity'],
  };
  // One entry per Agent, so a per-Agent answer is read from its own entry
  // rather than from a neighbouring one that happens to name the same helper.
  const entries = new Map();
  for (const chunk of registrations.split('    ParserRegistration::').slice(1)) {
    const contract = chunk.match(/(\w+)::CONTRACT/);
    if (contract) entries.set(contract[1], chunk);
  }
  assert.equal(entries.size, adapters.length - movedCount);
  for (const adapter of adapters) {
    const moved = movedParsers[adapter];
    if (moved) {
      // The composition names the package's registration, and — for a parser the
      // host still reads by name — the package's parser. The package's own
      // documents carry what this check would otherwise read here.
      if (moved.alias) {
        assert.ok(
          composition.includes(`use ${moved.crate}::parser as ${moved.alias};`),
          `${adapter}'s parser lives in ${moved.crate} and the composition names it`,
        );
      }
      assert.ok(
        registrations.includes(`${moved.crate}::registration::REGISTRATION`),
        `${adapter}'s registration is the package's own declaration`,
      );
      const owner = readFileSync(moved.registration, 'utf8');
      assert.match(owner, moved.constructor, `${adapter}'s registration constructor`);
      for (const answer of moved.answers) {
        assert.match(owner, new RegExp(`\\b${answer}\\b`, 'u'));
      }
      assert.match(readFileSync(moved.component, 'utf8'), /AdapterContract::new/);
      continue;
    }
    assert.match(composition, new RegExp(`mod ${adapter};`));
    const entry = entries.get(adapter);
    assert.ok(entry, `no registration entry for ${adapter}`);
    if (answered[adapter]) {
      assert.match(entry, /^new\(/u);
      for (const answer of answered[adapter]) {
        assert.match(entry, new RegExp(`\\b${answer}\\b`, 'u'));
      }
    } else {
      assert.match(entry, /^unanswered\(/u);
    }
    const component = readFileSync(
      `${parserRoot}/adapters/${adapter}.rs`,
      'utf8',
    );
    assert.match(component, /AdapterContract::new/);
  }
});

test('the shared adapter contract names no Agent', () => {
  const contract = [
    readFileSync(`${sdkRoot}/adapters/mod.rs`, 'utf8'),
    readFileSync(`${sdkRoot}/registry.rs`, 'utf8'),
    readFileSync(`${sdkRoot}/port.rs`, 'utf8'),
    readFileSync(`${sdkRoot}/lifecycle.rs`, 'utf8'),
    readFileSync(`${sdkRoot}/reconciliation.rs`, 'utf8'),
    readFileSync(`${sdkRoot}/replay/mod.rs`, 'utf8'),
  ].join('\n');
  for (const adapter of adapters) {
    assert.doesNotMatch(contract, new RegExp(`\\b${adapter}\\b`));
  }
});

test('normalized runtime responses cross the typed final parser boundary', () => {
  const normalization = readFileSync(
    'crates/licoup-agent-drivers/src/runtime_adapters/normalization.rs',
    'utf8',
  );
  assert.match(normalization, /execution\s*\.transitions/);
  assert.doesNotMatch(normalization, /native_agent_parser::parse_execution/);
  assert.match(normalization, /"events": transitions/);
  assert.doesNotMatch(normalization, /"events": execution\.events/);
  const parserCore = [
    readFileSync(`${sdkRoot}/adapters/mod.rs`, 'utf8'),
    readFileSync(`${sdkRoot}/registry.rs`, 'utf8'),
  ].join('\n');
  assert.doesNotMatch(parserCore, /ReturnedFrames|DecodePolicy|decode_execution/);

  const service = readFileSync(
    'crates/licoup-native/src/domain/client_conversation/service.rs',
    'utf8',
  );
  assert.match(service, /compose_generated_instruction_delivery/);
  const persistentServer = readFileSync(
    'crates/licoup-native/src/bin/licoup/stdio_rpc/server/conversation.rs',
    'utf8',
  );
  assert.match(persistentServer, /context\.private_instructions\(\)/);
  assert.match(persistentServer, /compose_generated_instruction_delivery/);
});

test('serve HTTP and SSE frames decode only in target parser components', () => {
  const neutralServe = readFileSync(
    'crates/licoup-agent-drivers/src/local_service/serve.rs',
    'utf8',
  );
  assert.doesNotMatch(neutralServe, /message\.updated|message\.part\.updated|serde_json::from_str/);

  for (const adapter of ['opencode', 'kilo_code']) {
    const parser = readFileSync(`${parserRoot}/adapters/${adapter}.rs`, 'utf8');
    assert.match(parser, /struct ServeEventParser/);
    assert.match(parser, /fn session_id/);
    assert.match(parser, /fn message/);
    assert.match(parser, /message\.part\.updated/);
  }
  const openCodeTransport = readFileSync(
    'crates/licoup-native/src/platform/opencode_driver/serve_transport.rs',
    'utf8',
  );
  const kiloTransport = readFileSync(
    'crates/licoup-native/src/platform/kilo_code_driver/transport.rs',
    'utf8',
  );
  assert.match(openCodeTransport, /adapters::opencode as serve_parser/);
  assert.match(kiloTransport, /adapters::kilo_code as serve_parser/);
});

test('Cursor PTY isolation precedes its strict NDJSON parser', () => {
  const transport = readFileSync(
    'crates/licoup-native/src/platform/cursor_driver/io.rs',
    'utf8',
  );
  const parser = readFileSync(`${parserRoot}/adapters/cursor.rs`, 'utf8');
  assert.match(transport, /isolate_pty_protocol_line/);
  assert.doesNotMatch(parser, /strip_pty_controls|isolate_pty_protocol_line/);
  assert.match(parser, /serde_json::from_slice/);
});

test('interaction and lifecycle authorities are unbounded and write-once', () => {
  const interaction = readFileSync(
    'crates/licoup-foundation/src/platform/native_agent_interaction/mod.rs',
    'utf8',
  );
  assert.match(interaction, /in-process-one-shot/);
  const productionInteraction = interaction.slice(
    0,
    interaction.indexOf("pub(in crate::platform) fn pending_token"),
  );
  assert.doesNotMatch(productionInteraction, /expires_at|deadline:/i);
  const approvalRoute = readFileSync(
    'crates/licoup-agent-drivers/src/acp_session_transport/approval_store.rs',
    'utf8',
  );
  assert.doesNotMatch(approvalRoute, /PARKED_PERMISSIONS|ParkedPermission/);
  assert.match(approvalRoute, /native_agent_interaction::resolve/);

  // The lifecycle reducer moved to the adapter SDK, which owns it now. The
  // first failure stays write-once, and the stages stay prefix closed: the
  // reducer walks the declared machine from its initial state to the reported
  // one rather than emitting a stage list of its own.
  const lifecycle = readFileSync(`${sdkRoot}/lifecycle.rs`, 'utf8');
  assert.match(lifecycle, /if self\.failure\.is_some\(\)/);
  assert.match(lifecycle, /parser_lifecycle::INITIAL/);
  assert.match(lifecycle, /parser_lifecycle::transition\(current, Event::Advance\)/);
  const machine = readFileSync(
    'crates/licoup-agent-adapter-sdk/resources/state-machines/parser-lifecycle.json',
    'utf8',
  );
  const declared = JSON.parse(machine).machines;
  assert.equal(declared.length, 1);
  assert.deepEqual(declared[0].terminal, ['completed']);
  assert.equal(declared[0].initial, 'submitted');
});
