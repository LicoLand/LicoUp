import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import test from 'node:test';

// The thirteen per-Agent parsers and the composition that names them stay in the
// host until that Agent's own package owns the protocol; the shared adapter
// contract, the registry lookup, the replay harness and the lifecycle authority
// moved to `licoup-agent-adapter-sdk`. Thirteen Agents have moved further: their
// vendor protocol, wire vocabulary, parser declaration and replay arm are their
// own package's, and the composition names the package instead of keeping a
// second copy. Everything below is derived from the two maps, so adding the
// next Agent's package changes a map and not a count.
const parserRoot = 'crates/licoup-native/src/platform/native_agent_parser';
const compositionRoot = `${parserRoot}/adapters`;
const sdkRoot = 'crates/licoup-agent-adapter-sdk/src';

// Every adapter this composition carries, in `RuntimeAdapter` order.
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
  'pi',
  'lico_agent',
  'deepseek_harness',
];
// The Agents whose protocol is a package's own: their parser module, their
// declaration and their replay arm live in the package's crate. Every fact the
// boundary reads for one of them is named here once, as a literal — the crate,
// the module inside that crate which exposes the parser, the source publishing
// the declaration, the contract id that declaration carries, and whether this
// composition reads that parser. Nothing below is derived by rewriting a name:
// `kimi_code` is `licoup_agent_kimi` because this table says so, and the crate
// whose parser module sits deeper than `parser` writes that path here.
const packaged = {
  antigravity: {
    crate: 'licoup_agent_antigravity',
    module: 'parser',
    source: 'crates/licoup-agent-antigravity/src/parser.rs',
    contractId: 'antigravity',
    readsParser: true,
  },
  claude_code: {
    crate: 'licoup_agent_claude_code',
    module: 'protocol::parser',
    source: 'crates/licoup-agent-claude-code/src/protocol/parser.rs',
    contractId: 'claude-code',
    readsParser: false,
  },
  codex: {
    crate: 'licoup_agent_codex',
    module: 'parser',
    source: 'crates/licoup-agent-codex/src/parser.rs',
    contractId: 'codex',
    readsParser: false,
  },
  copilot: {
    crate: 'licoup_agent_copilot',
    module: 'parser',
    source: 'crates/licoup-agent-copilot/src/parser.rs',
    contractId: 'copilot',
    readsParser: false,
  },
  cursor: {
    crate: 'licoup_agent_cursor',
    module: 'parser',
    source: 'crates/licoup-agent-cursor/src/parser.rs',
    contractId: 'cursor',
    readsParser: true,
  },
  deepseek_harness: {
    crate: 'licoup_agent_deepseek',
    module: 'parser',
    source: 'crates/licoup-agent-deepseek/src/parser.rs',
    contractId: 'deepseek-harness',
    readsParser: false,
  },
  hermes: {
    crate: 'licoup_agent_hermes',
    module: 'parser',
    source: 'crates/licoup-agent-hermes/src/parser.rs',
    contractId: 'hermes',
    readsParser: false,
  },
  kilo_code: {
    crate: 'licoup_agent_kilo',
    module: 'parser',
    source: 'crates/licoup-agent-kilo/src/parser/mod.rs',
    contractId: 'kilo-code',
    readsParser: false,
  },
  kimi_code: {
    crate: 'licoup_agent_kimi',
    module: 'parser',
    source: 'crates/licoup-agent-kimi/src/parser.rs',
    contractId: 'kimi-code',
    readsParser: false,
  },
  lico_agent: {
    crate: 'licoup_agent_lico_agent',
    module: 'parser',
    source: 'crates/licoup-agent-lico-agent/src/parser.rs',
    contractId: 'lico-agent',
    readsParser: false,
  },
  openclaw: {
    crate: 'licoup_agent_openclaw',
    module: 'parser',
    source: 'crates/licoup-agent-openclaw/src/parser.rs',
    contractId: 'openclaw',
    readsParser: false,
  },
  opencode: {
    crate: 'licoup_agent_opencode',
    module: 'parser',
    source: 'crates/licoup-agent-opencode/src/parser.rs',
    contractId: 'opencode',
    readsParser: true,
  },
  pi: {
    crate: 'licoup_agent_pi',
    module: 'parser',
    source: 'crates/licoup-agent-pi/src/parser.rs',
    contractId: 'pi',
    readsParser: true,
  },
};

// The one Agent whose normalized transitions the host reads through the SDK's
// query rather than from its own execution result: Hermes reports no transition
// list with a turn, so the package that owns its parser owns that answer, and a
// fail-closed identity stays beside it. The fact is asserted on the package the
// composition names, because that is where the answer now lives.
const packagedAnswers = {
  hermes: {
    registration: 'crates/licoup-agent-hermes/src/registration.rs',
    answers: ['execution_transitions', 'no_identity'],
  },
};

// The packaged parsers this composition reads, derived from the table so the two
// cannot drift: a parser alias belongs exactly where a production reader reads
// the parser, and an alias kept for an Agent nothing reads is the unused import
// the compiler reports.
const readParserAliases = new Set(
  Object.entries(packaged)
    .filter(([, moved]) => moved.readsParser)
    .map(([adapter]) => adapter),
);

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
  assert.equal(packageEntries, Object.keys(packaged).length);
  // No entry this composition still holds answers a protocol-agnostic query:
  // Hermes' normalized transitions moved with its parser into the package that
  // owns them (asserted below), the Agents the Subagent mesh dispatches answer
  // their identity from their own packages, and every remaining host-held entry
  // reports its transitions with its own execution result and stays fail-closed
  // on identity rather than inheriting a neighbouring Agent's answer.
  const answered = {};
  // One entry per Agent, so a per-Agent answer is read from its own entry
  // rather than from a neighbouring one that happens to name the same helper.
  // A moved Agent's entry is its package's registration constant, which the
  // package's own suite proves answers both queries.
  const entries = new Map();
  for (const chunk of registrations.split('    ParserRegistration::').slice(1)) {
    const contract = chunk.match(/(\w+)::CONTRACT/);
    if (contract) entries.set(contract[1], chunk);
  }
  assert.equal(entries.size, 13 - Object.keys(packaged).length);
  for (const adapter of adapters) {
    const moved = packaged[adapter];
    const source = readFileSync(
      moved ? moved.source : `${parserRoot}/adapters/${adapter}.rs`, 'utf8');
    assert.match(source, /AdapterContract::new/);
    if (moved) {
      // The package owns the parser, the declaration and the replay arm. The
      // composition reaches that Agent through the package's own crate, names
      // the package's own REGISTRATION constant, may not declare the module, and
      // may not restate the declaration the package publishes.
      assert.ok(composition.includes(`${moved.crate}::`),
        `${adapter} must be reached through ${moved.crate}`);
      assert.match(registrations,
        new RegExp(`${moved.crate}::registration::REGISTRATION`));
      assert.doesNotMatch(composition, new RegExp(`mod ${adapter};`));
      // The contract id is the package's, so it is read from the package: the
      // table records it and the composition may not carry a second copy of it.
      assert.match(source, new RegExp(`AdapterContract::new\\("${moved.contractId}"`),
        `${adapter}'s parser publishes the contract id this table records`);
      assert.doesNotMatch(composition,
        new RegExp(`AdapterContract::new\\("${moved.contractId}"`),
        `${adapter}'s declaration is the package's, not a second one here`);
      // A package alias is the composition naming the package's parser in order
      // to read it. The assertion is bidirectional: the alias is there exactly
      // when the table says a production reader reads that parser, so removing a
      // needed alias and re-adding an unread one both fail here.
      const alias = `use ${moved.crate}::${moved.module} as ${adapter};`;
      assert.equal(composition.includes(alias), readParserAliases.has(adapter),
        `${adapter} composes \`${alias}\` exactly where production reads its parser`);
      // The answer travels with the parser as well: the package's own
      // registration is the one that answers, and it answers with its own
      // functions rather than inheriting the SDK's fail-closed default.
      const packagedAnswer = packagedAnswers[adapter];
      if (packagedAnswer) {
        const registration = readFileSync(packagedAnswer.registration, 'utf8');
        assert.match(registration, /ParserRegistration::new\(/u);
        for (const answer of packagedAnswer.answers) {
          assert.match(registration, new RegExp(`\\b${answer}\\b`, 'u'));
        }
      }
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
    const component = readFileSync(`${parserRoot}/adapters/${adapter}.rs`, 'utf8');
    assert.match(component, /AdapterContract::new/);
  }
  // The other direction of the alias rule: every package parser the composition
  // composes is a row of this table that says production reads it. A second name
  // for a package parser — a new alias, or the alias an unread parser would leave
  // behind — fails here even under a name the loop above never asks about.
  const composed = [...composition.matchAll(
    /use\s+(licoup_agent_[a-z_]+)::([A-Za-z_][A-Za-z0-9_:]*?)\s+as\s+([a-z_][A-Za-z0-9_]*)\s*;/g,
  )].map(([, crate, module, alias]) => ({ crate, module, alias }));
  for (const { crate, module, alias } of composed) {
    const moved = packaged[alias];
    assert.ok(moved,
      `the composition composes ${crate}::${module} as ${alias}, which no package row records`);
    assert.deepEqual({ crate: moved.crate, module: moved.module }, { crate, module },
      `${alias} composes the module its package row names`);
    assert.ok(moved.readsParser,
      `${alias} is composed as a package parser but no production reader reads it`);
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
  // from the package root; OpenCode's moved the same way, so its protocol text is
  // read from the file the package table records rather than from a host copy
  // that the composition check above would fail.
  const kiloParser = readFileSync(
    'crates/licoup-agent-kilo/src/parser/serve.rs',
    'utf8',
  );
  assert.match(kiloParser, /struct ServeEventParser/);
  assert.match(kiloParser, /message\.part\.updated/);
  const kiloProtocol = readFileSync('crates/licoup-agent-kilo/src/parser/mod.rs', 'utf8');
  assert.match(kiloProtocol, /fn session_id/);
  assert.match(kiloProtocol, /fn message/);
  const openCodeParser = readFileSync(packaged.opencode.source, 'utf8');
  assert.match(openCodeParser, /struct ServeEventParser/);
  assert.match(openCodeParser, /fn session_id/);
  assert.match(openCodeParser, /fn message/);
  assert.match(openCodeParser, /message\.part\.updated/);
  const openCodeTransport = readFileSync(
    'crates/licoup-agent-opencode/src/driver/serve_transport.rs',
    'utf8',
  );
  // The Kilo turn is the package's own composition: it asks the installed serve
  // engine for the effect and reads the package's parser, not a transport that
  // classifies frames of its own.
  const kiloTransport = readFileSync(
    'crates/licoup-agent-kilo/src/driver/turn.rs',
    'utf8',
  );
  // OpenCode's own driver reads its package's parser directly, so the frames are
  // classified once and below the port the client answers, and the kernel keeps
  // no driver tree of its own to read them through.
  assert.match(openCodeTransport, /use crate::parser as serve_parser;/);
  assert.match(readFileSync(
    'crates/licoup-agent-opencode/src/driver/probe.rs',
    'utf8',
  ), /use crate::parser as serve_parser;/);
  assert.equal(existsSync(
    'crates/licoup-native/src/platform/opencode_driver.rs',
  ), false);
  // The composition names the package's parser as `opencode`, which is the name
  // the client's endpoint specification reads this Agent's readiness by.
  const composition = readFileSync(`${compositionRoot}/mod.rs`, 'utf8');
  assert.match(
    composition,
    new RegExp(`use ${packaged.opencode.crate}::parser as opencode;`),
  );
  // The kernel keeps no driver tree of its own to read OpenCode's frames
  // through: the readiness the endpoint specification asks for is the parser the
  // composition names above.
  assert.match(readFileSync(
    'crates/licoup-native/src/platform/opencode_serve/policy.rs',
    'utf8',
  ), /adapters::opencode::readiness/);
  // The Kilo turn reads the package's own parser rather than a local copy, which
  // is what makes the corpus a statement about the shipped ingress, and the
  // client keeps no Kilo transport for it to be read from.
  assert.match(kiloTransport, /execute_via_serve/);
  assert.match(kiloTransport, /crate::parser/);
  assert.equal(
    existsSync('crates/licoup-native/src/platform/kilo_code_driver/execution.rs'),
    false,
    'the host still keeps a Kilo Code transport',
  );
});

test('Cursor PTY isolation precedes its strict NDJSON parser', () => {
  const transport = readFileSync(
    'crates/licoup-agent-cursor/src/driver/io.rs',
    'utf8',
  );
  // The PTY isolation stays in the process half — the Cursor package's driver
  // now — while the parser it hands a clean line to is that package's own, and
  // it reads no PTY control at all.
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
