import { command, defineModule } from "../helpers.mjs";

function crateTests(id, summary, crate, inputs) {
  const manifest = `crates/${crate}/Cargo.toml`;
  return defineModule({
    id,
    kind: "rust-crate",
    summary,
    inputs: [manifest, ...inputs],
    command: command(
      "cargo",
      ["test", "--manifest-path", manifest],
      10 * 60_000,
    ),
  });
}

export const RUST_COMPONENT_MODULES = Object.freeze([
  crateTests(
    "rust.crate.agent-runtime",
    "Agent runtime work-context authority and protocol-neutral session state",
    "licoup-agent-runtime",
    ["crates/licoup-agent-runtime/tests/work_context.rs"],
  ),
  crateTests(
    "rust.crate.application-contracts",
    "Protocol-neutral application commands, dependency direction, and extension contracts",
    "licoup-application",
    [
      "crates/licoup-application/tests/command_contract.rs",
      "crates/licoup-application/tests/dependency_boundary.rs",
      "crates/licoup-application/tests/extension_contract.rs",
    ],
  ),
  crateTests(
    "rust.crate.conversation-contracts",
    "Conversation continuity contract and configured state-machine invariants",
    "licoup-conversation",
    [
      "crates/licoup-conversation/tests/continuity_contract.rs",
      "crates/licoup-conversation/tests/state_machine_proptest.rs",
      "tests/fixtures/continuous-assistant/contracts/**",
    ],
  ),
  crateTests(
    "rust.crate.extension-contracts",
    "Published extension schemas, sample vectors, and portable extension behavior",
    "licoup-extension-contracts",
    [
      "crates/licoup-extension-contracts/samples/**",
      "crates/licoup-extension-contracts/tests/minimal_agent_sample.rs",
      "crates/licoup-extension-contracts/tests/schema_agreement.rs",
      "schemas/extensions/**",
    ],
  ),
  crateTests(
    "rust.crate.state-machine-codegen",
    "Deterministic state-machine generation and invalid transition rejection",
    "licoup-state-machine-codegen",
    [
      "crates/licoup-state-machine-codegen/tests/compiler.rs",
    ],
  ),
]);
