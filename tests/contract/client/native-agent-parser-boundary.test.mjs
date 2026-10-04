import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

// The per-Agent parsers the host still holds and the composition that names
// them; the shared adapter contract, the registry lookup, the replay harness
// and the lifecycle authority moved to `licoup-agent-adapter-sdk`. Two Agents
// have moved further: their vendor protocol, wire vocabulary and replay arm are
// their own package's, and the composition names the package instead of keeping
// a second copy.
// The thirteen per-Agent parsers and the composition that names them stay in
// the host until that Agent's own package owns the protocol; the shared adapter
// contract, the registry lookup, the replay harness and the lifecycle authority
// moved to `licoup-agent-adapter-sdk`.
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
// The Agents whose protocol is a package's own: their parser module, their
// declaration and their replay arm live in the package's crate.
const packageAdapters = new Map([
  ['antigravity', 'crates/licoup-agent-antigravity'],
  ['codex', 'crates/licoup-agent-codex'],
  ['cursor', 'crates/licoup-agent-cursor'],
  ['deepseek_harness', 'crates/licoup-agent-deepseek'],
  ['kimi_code', 'crates/licoup-agent-kimi'],
]);

// The package-owned parsers, under the alias the composition composes them by:
// the crate that owns the parser, and the parser source the package ships.
const packaged = {
  antigravity: {
    crate: 'licoup_agent_antigravity',
    parser: 'crates/licoup-agent-antigravity/src/parser.rs',
  },
  codex: {
    crate: 'licoup_agent_codex',
    parser: 'crates/licoup-agent-codex/src/parser.rs',
  },
  cursor: {
    crate: 'licoup_agent_cursor',
    parser: 'crates/licoup-agent-cursor/src/parser.rs',
  },
  deepseek_harness: {
    crate: 'licoup_agent_deepseek',
    parser: 'crates/licoup-agent-deepseek/src/parser.rs',
  },
  kimi_code: {
    crate: 'licoup_agent_kimi',
    parser: 'crates/licoup-agent-kimi/src/parser.rs',
  },
};

test('packaged adapter registry is bijective with the thirteen-entry inventory', () => {
  const composition = readFileSync(`${compositionRoot}/mod.rs`, 'utf8');
  const registrations = composition.slice(
    composition.indexOf('pub(in crate::platform) static REGISTRATIONS'),
    composition.indexOf('/// The parser registrations this host injects'),
  );
  // Every entry names its Agent's declaration exactly once, and none inherits
  // another Agent's answer. The entries a package owns are that package's own
  // registration constant, counted from the package map rather than restated.
  const hostedEntries =
    (registrations.match(/ParserRegistration::(?:unanswered|new)\(/g) ?? []).length;
  const packageEntries =
    (registrations.match(/licoup_agent_\w+::registration::REGISTRATION/g) ?? []).length;
  assert.equal(hostedEntries + packageEntries, 13);
  assert.equal(packageEntries, packageAdapters.size);
  // The queries a reader reaches are answered by the Agent that owns the fact:
  // Hermes' normalized transitions, and the exact-resume identity of the Agents
  // the Subagent mesh dispatches. Every other entry stays declared and
  // unanswered rather than inheriting a neighbouring Agent's answer, and a
  // package entry answers from the package's own evidence.
  const answered = {
    claude_code: ['no_transitions', 'claude_code_identity'],
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
  assert.equal(entries.size, 13 - Object.keys(packaged).length);
  for (const adapter of adapters) {
    const moved = packaged[adapter];
    const source = readFileSync(
      moved ? moved.parser : `${parserRoot}/adapters/${adapter}.rs`, 'utf8');
    assert.match(source, /AdapterContract::new/);
    if (moved) {
      // The package owns the parser, the declaration and the replay arm; the
      // composition reads them through the package's own module, may not declare
      // the module, and names the package's own registration constant.
      assert.match(composition,
        new RegExp(`use ${moved.crate}::parser as ${adapter};`));
      assert.match(registrations,
        new RegExp(`${moved.crate}::registration::REGISTRATION`));
      assert.doesNotMatch(composition, new RegExp(`mod ${adapter};`));
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
  // The PTY isolation stays in the host's process half; the parser it hands a
  // clean line to is the package's own, and it reads no PTY control at all.
  const parser = readFileSync(
    'crates/licoup-agent-cursor/src/parser.rs',
    'utf8',
  );
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
