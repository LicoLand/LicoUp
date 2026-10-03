import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

// The thirteen per-Agent parsers and the composition that names them stay in
// the host; the shared adapter contract, the registry lookup, the replay
// harness and the lifecycle authority moved to `licoup-agent-adapter-sdk`.
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

test('packaged adapter registry is bijective with the thirteen-entry inventory', () => {
  const composition = readFileSync(`${compositionRoot}/mod.rs`, 'utf8');
  const registrations = composition.slice(
    composition.indexOf('pub(in crate::platform) static REGISTRATIONS'),
    composition.indexOf('/// The parser registrations this host injects'),
  );
  // Every entry names its Agent's declaration exactly once, and none inherits
  // another Agent's answer. Two Agents' parsers have moved into their own
  // packages, so a moved Agent's entry is the package's own registration
  // constant rather than a `ParserRegistration::` constructor here.
  const inline = (registrations.match(/ParserRegistration::(?:unanswered|new)\(/g) ?? []).length;
  const moved = (registrations.match(/licoup_agent_\w+::registration::REGISTRATION/g) ?? []).length;
  assert.equal(inline + moved, 13);
  assert.equal(moved, 2, 'the two moved parsers are named by their own packages');
  for (const crate of ['licoup_agent_codex', 'licoup_agent_kilo']) {
    assert.match(
      composition,
      new RegExp(`^pub\\(in crate::platform\\) use ${crate}::parser as (\\w+);`, 'mu'),
      `${crate} must be named as a package, not kept as a second copy`,
    );
  }
  // The queries a reader reaches are answered by the Agent that owns the fact:
  // Hermes' normalized transitions, and the exact-resume identity of the four
  // Agents the Subagent mesh dispatches. Every other entry stays declared and
  // unanswered rather than inheriting a neighbouring Agent's answer.
  const answered = {
    antigravity: ['no_transitions', 'antigravity_identity'],
    claude_code: ['no_transitions', 'claude_code_identity'],
    cursor: ['no_transitions', 'cursor_identity'],
    hermes: ['hermes_transitions', 'no_identity'],
  };
  // One entry per Agent, so a per-Agent answer is read from its own entry
  // rather than from a neighbouring one that happens to name the same helper.
  // A moved Agent's entry is its package's registration constant, which the
  // package's own suite proves answers both queries.
  const entries = new Map();
  for (const chunk of registrations.split('    ParserRegistration::').slice(1)) {
    const contract = chunk.match(/(\w+)::CONTRACT/);
    if (contract) entries.set(contract[1], chunk);
  }
  for (const [adapter, module] of [
    ['codex', 'licoup_agent_codex'],
    ['kilo_code', 'licoup_agent_kilo'],
  ]) {
    entries.set(adapter, `${module}::registration::REGISTRATION`);
  }
  assert.equal(entries.size, 13);
  // A moved Agent's declaration lives in its own package, at the path that
  // package chose for its protocol module.
  const movedAdapters = new Map([
    ['codex', ['licoup_agent_codex', 'crates/licoup-agent-codex/src/parser.rs']],
    ['kilo_code', ['licoup_agent_kilo', 'crates/licoup-agent-kilo/src/parser/mod.rs']],
  ]);
  for (const adapter of adapters) {
    if (!movedAdapters.has(adapter)) assert.match(composition, new RegExp(`mod ${adapter};`));
    const entry = entries.get(adapter);
    assert.ok(entry, `no registration entry for ${adapter}`);
    if (movedAdapters.has(adapter)) {
      // A moved Agent's entry is its package's registration constant, and the
      // package's own suite proves it answers both protocol-agnostic queries
      // rather than inheriting a neighbour's answer.
      assert.match(entry, /registration::REGISTRATION$/u);
      const movedContract = readFileSync(movedAdapters.get(adapter)[1], 'utf8');
      assert.match(movedContract, /AdapterContract::new/u);
      continue;
    }
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

  // Kilo Code's parser moved into its own package, so its protocol text is read
  // from the package root; OpenCode's is still composed by the client.
  const kiloParser = readFileSync(
    'crates/licoup-agent-kilo/src/parser/serve.rs',
    'utf8',
  );
  assert.match(kiloParser, /struct ServeEventParser/);
  assert.match(kiloParser, /message\.part\.updated/);
  const kiloProtocol = readFileSync('crates/licoup-agent-kilo/src/parser/mod.rs', 'utf8');
  assert.match(kiloProtocol, /fn session_id/);
  assert.match(kiloProtocol, /fn message/);
  const openCodeParser = readFileSync(`${parserRoot}/adapters/opencode.rs`, 'utf8');
  assert.match(openCodeParser, /struct ServeEventParser/);
  assert.match(openCodeParser, /fn session_id/);
  assert.match(openCodeParser, /fn message/);
  assert.match(openCodeParser, /message\.part\.updated/);
  const openCodeTransport = readFileSync(
    'crates/licoup-native/src/platform/opencode_driver/serve_transport.rs',
    'utf8',
  );
  // The client's Kilo turn is the composition that asks the package to perform
  // it, not a transport that classifies frames of its own.
  const kiloTransport = readFileSync(
    'crates/licoup-native/src/platform/kilo_code_driver/execution.rs',
    'utf8',
  );
  assert.match(openCodeTransport, /adapters::opencode as serve_parser/);
  // The client's Kilo turn reads the package's own parser rather than a local
  // copy, which is what makes the corpus a statement about the shipped ingress.
  assert.match(kiloTransport, /driver::execute_via_serve|licoup_agent_kilo/);
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
