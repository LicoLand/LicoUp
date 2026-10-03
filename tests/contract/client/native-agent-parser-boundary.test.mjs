import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

// The per-Agent parsers that are still the host's and the composition that names
// them stay in the host; the shared adapter contract, the registry lookup, the
// replay harness and the lifecycle authority moved to
// `licoup-agent-adapter-sdk`, and two Agents' protocols moved into their own
// packages (`licoup-agent-codex`, `licoup-agent-claude-code`).
const parserRoot = 'crates/licoup-native/src/platform/native_agent_parser';
const compositionRoot = `${parserRoot}/adapters`;
const sdkRoot = 'crates/licoup-agent-adapter-sdk/src';

// Every adapter the packaged inventory declares, in `RuntimeAdapter` order, and
// where its parser declaration lives: `host` is a module beside the composition,
// `package` is an adapter package this composition names.
const inventory = [
  { adapter: 'antigravity', owner: 'host' },
  { adapter: 'claude_code', owner: 'package', package: 'licoup-agent-claude-code' },
  { adapter: 'codex', owner: 'package', package: 'licoup-agent-codex' },
  { adapter: 'copilot', owner: 'host' },
  { adapter: 'cursor', owner: 'host' },
  { adapter: 'hermes', owner: 'host' },
  { adapter: 'kilo_code', owner: 'host' },
  { adapter: 'kimi_code', owner: 'host' },
  { adapter: 'openclaw', owner: 'host' },
  { adapter: 'opencode', owner: 'host' },
  { adapter: 'pi', owner: 'host' },
  { adapter: 'lico_agent', owner: 'host' },
  { adapter: 'deepseek_harness', owner: 'host' },
];

test('packaged adapter registry is bijective with the thirteen-entry inventory', () => {
  const composition = readFileSync(`${compositionRoot}/mod.rs`, 'utf8');
  const registrations = composition.slice(
    composition.indexOf('pub(in crate::platform) static REGISTRATIONS'),
    composition.indexOf('/// The parser registrations this host injects'),
  );
  // Every entry names its Agent's declaration exactly once, and none inherits
  // another Agent's answer. An entry is either a constructor over a declaration
  // this composition holds (`ParserRegistration::new` / `unanswered`) or the
  // registration an adapter package publishes for itself.
  const hostEntries = registrations.match(/ParserRegistration::(?:unanswered|new)\(/g) ?? [];
  const packageEntries = registrations.match(/\w+::registration::REGISTRATION/g) ?? [];
  assert.equal(
    hostEntries.length + packageEntries.length,
    inventory.length,
    'one registration entry per packaged adapter',
  );

  // The queries a reader reaches are answered by the Agent that owns the fact:
  // Hermes' normalized transitions, and the exact-resume identity of the four
  // Agents the Subagent mesh dispatches. Every other entry stays declared and
  // unanswered rather than inheriting a neighbouring Agent's answer.
  const answered = {
    antigravity: ['no_transitions', 'antigravity_identity'],
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
  for (const { adapter, owner, package: packageName } of inventory) {
    if (owner === 'host') {
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
      const component = readFileSync(`${parserRoot}/adapters/${adapter}.rs`, 'utf8');
      assert.match(component, /AdapterContract::new/);
      continue;
    }
    // A package-owned parser keeps no copy beside the composition: the entry is
    // the package's own registration, and the package's crate declares the
    // adapter contract its parser reports.
    assert.equal(
      composition.includes(`mod ${adapter};`),
      false,
      `${adapter} moved into ${packageName} and is not a host module`,
    );
    assert.match(
      composition,
      new RegExp(`${packageName.replaceAll('-', '_')}::registration::REGISTRATION`),
      `the composition names ${packageName} for ${adapter}`,
    );
    // A package's parser declaration sits at the root of its own protocol
    // module: `parser.rs` beside `app_server/` for Codex, `protocol/parser.rs`
    // for Claude Code.
    const declaration = readFileSync(
      packageName === "licoup-agent-codex"
        ? `crates/${packageName}/src/parser.rs`
        : `crates/${packageName}/src/protocol/parser.rs`,
      "utf8",
    );
    assert.match(declaration, /AdapterContract::new/);
    const registration = readFileSync(
      `crates/${packageName}/src/registration.rs`,
      'utf8',
    );
    assert.match(registration, /pub const REGISTRATION: ParserRegistration/);
  }
  assert.equal(entries.size, inventory.filter(({ owner }) => owner === 'host').length);
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
  for (const { adapter } of inventory) {
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
