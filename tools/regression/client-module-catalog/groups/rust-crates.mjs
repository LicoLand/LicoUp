import { command, defineModule } from "../helpers.mjs";

const crateTests = (crate) => command(
  "cargo",
  [
    "test",
    "--manifest-path",
    `crates/${crate}/Cargo.toml`,
  ],
  10 * 60_000,
);

/**
 * Standalone workspace crates that carry their own manifest and complete test
 * surface. Each entry owns one crate root so a change anywhere in the crate
 * selects its own focused `cargo test` instead of a native-host aggregate.
 */
export const RUST_CRATE_MODULES = Object.freeze([
  defineModule({
    id: "rust.development.state-machine-codegen",
    kind: "rust-crate",
    summary: "Declarative state-machine compiler validation and generated transition behavior",
    inputs: ["crates/licoup-state-machine-codegen/**"],
    command: crateTests("licoup-state-machine-codegen"),
  }),
  defineModule({
    id: "rust.crate.agent-runtime",
    kind: "rust-crate",
    summary: "Portable Agent runtime and adapter contracts",
    inputs: ["crates/licoup-agent-runtime/**", "crates/licoup-agent-adapters/**"],
    command: command("cargo", ["test", "-p", "licoup-agent-runtime", "-p", "licoup-agent-adapters"], 10 * 60_000),
  }),
  defineModule({
    id: "rust.platform.host-integration",
    kind: "rust-crate",
    summary: "Native host workflow and conversation integration",
    inputs: ["crates/licoup-native/tests/host_runtime/**"],
    command: command("cargo", ["test", "--manifest-path", "crates/licoup-native/Cargo.toml", "--test", "host_runtime"], 20 * 60_000),
  }),
  defineModule({
    id: "rust.conversation.local-flow",
    kind: "rust-crate",
    summary: "Local conversation streaming, continuation, cancellation and durable reopening",
    inputs: ["crates/licoup-conversation/src/store/**", "crates/licoup-conversation/tests/local_conversation.rs"],
    command: command("cargo", ["test", "-p", "licoup-conversation", "--test", "local_conversation"], 10 * 60_000),
  }),
  defineModule({
    id: "rust.conversation.state-machine",
    kind: "rust-crate",
    summary: "Configuration-driven Conversation lifecycle transitions and terminal monotonicity",
    inputs: [
      "crates/licoup-conversation/build.rs",
      "crates/licoup-conversation/resources/**",
      "crates/licoup-conversation/src/state_machine/**",
      "crates/licoup-conversation/tests/state_machine_proptest.rs",
    ],
    command: command("cargo", ["test", "-p", "licoup-conversation", "--test", "state_machine_proptest"], 10 * 60_000),
  }),
  defineModule({
    id: "rust.workflow.recovery-successor",
    kind: "rust-crate",
    summary: "Real checkpoint admission, old-owner fencing, effect reconciliation and successor CAS",
    inputs: ["crates/licoup-workflow-store/src/recovery/**", "crates/licoup-workflow-store/tests/recovery/**", "crates/licoup-workflow-runtime/src/successor/**"],
    command: command("cargo", ["test", "--locked", "--offline", "-p", "licoup-workflow-store", "--test", "recovery"], 20 * 60_000),
  }),
  defineModule({
    id: "rust.sdk.usage-source",
    kind: "rust-crate",
    summary: "Bounded, host-bound open usage-source collection and normalization",
    inputs: ["sdk/usage-source/**", "crates/licoup-extension-contracts/src/usage.rs"],
    command: command("cargo", ["test", "--locked", "--offline", "--manifest-path", "sdk/usage-source/Cargo.toml"], 20 * 60_000),
  }),
  defineModule({
    id: "rust.component.analytics",
    kind: "rust-crate",
    summary: "Optional metrics correction/correlation and borrowed core-fact preservation on removal",
    inputs: ["components/analytics/**", "sdk/usage-source/**", "tests/integration/usage_sources/**", "crates/licoup-extension-contracts/src/usage.rs"],
    command: command("cargo", ["test", "--locked", "--offline", "--manifest-path", "components/analytics/Cargo.toml"], 20 * 60_000),
  }),
  ...[
    {
      id: "rust.workflow.driver", target: "driver",
      summary: "Continuous per-result progress, actual admission limits, durable start and scope fences",
      inputs: ["crates/licoup-workflow-runtime/src/driver/**", "crates/licoup-workflow-runtime/src/node/**", "crates/licoup-workflow-runtime/tests/driver/**", "crates/licoup-workflow-runtime/src/admission/barrier.rs"],
    },
    {
      id: "rust.workflow.admission", target: "admission",
      summary: "Non-forgeable authority, actual reservation receipts, and run-keyed scope barriers",
      inputs: ["crates/licoup-workflow-runtime/src/admission/**", "crates/licoup-workflow-runtime/tests/admission/**"],
    },
  ].map(({ id, target, summary, inputs }) => defineModule({
    id, kind: "rust-crate", summary, inputs,
    command: command("cargo", ["test", "--locked", "--offline", "-p", "licoup-workflow-runtime", "--test", target], 20 * 60_000),
  })),
  ...[
    {
      id: "rust.workflow.plan-cache", crate: "licoup-workflow-runtime", filter: "plan_cache",
      summary: "Semantic-versioned single-flight compilation and actual byte-cache release",
      inputs: ["crates/licoup-workflow-runtime/src/plan_cache.rs", "crates/licoup-workflow/src/compile.rs"],
    },
    {
      id: "rust.workflow.routing", crate: "licoup-workflow-runtime", filter: "routing",
      summary: "Frozen notice acceptance sets, scope subscription lifecycle, and reserved routing lanes",
      inputs: ["crates/licoup-workflow-runtime/src/routing/**"],
    },
    {
      id: "rust.workflow.deliveries", crate: "licoup-workflow-store", filter: "deliveries",
      summary: "Durable notice queue fairness, sink admission, restart, and acknowledgement windows",
      inputs: ["crates/licoup-workflow-store/src/deliveries/**", "crates/licoup-workflow-store/src/schema/**", "crates/licoup-workflow-runtime/src/routing/**"],
    },
    {
      id: "rust.conversation.workflow-notices", crate: "licoup-conversation", filter: "workflow_notices",
      summary: "One durable Conversation notice identity across independent projection and wake obligations",
      inputs: ["crates/licoup-conversation/src/continuity/workflow_notices.rs"],
    },
  ].map(({ id, crate, filter, summary, inputs }) => defineModule({
    id, kind: "rust-crate", summary, inputs,
    command: command("cargo", ["test", "--locked", "--offline", "-p", crate, "--lib", filter], 20 * 60_000),
  })),
  defineModule({
    id: "rust.workflow.transactions",
    kind: "rust-crate",
    summary: "Actual SQLite CAS, atomic checkpoint/effect/outbox persistence, reopen, and production-shape fixtures",
    inputs: [
      "crates/licoup-workflow-store/src/transactions/**",
      "crates/licoup-workflow-store/src/schema/**",
      "crates/licoup-workflow-store/tests/transactions/**",
      "crates/licoup-workflow-runtime/src/ports.rs",
      "crates/licoup-workflow/src/ir.rs",
      "crates/licoup-workflow/src/machine.rs",
    ],
    command: command("cargo", [
      "test", "--locked", "--offline", "-p", "licoup-workflow-store", "--test", "transactions",
    ], 20 * 60_000),
  }),
  defineModule({
    id: "rust.sdk.model-provider",
    kind: "rust-crate",
    summary: "Provider configuration generations, scoped credentials, and real custom stream processes",
    inputs: [
      "sdk/model-provider/**",
      "extensions/providers/**",
      "tests/integration/model_providers/**",
      "crates/licoup-application/**",
      "crates/licoup-extension-contracts/**",
    ],
    command: command("cargo", [
      "test", "--locked", "--offline", "--manifest-path", "sdk/model-provider/Cargo.toml",
    ], 20 * 60_000),
  }),
  defineModule({
    id: "rust.crate.application",
    kind: "rust-crate",
    summary: "Portable application invocation, capability, receipt, and extension catalog contract",
    inputs: [
      "crates/licoup-application/**",
    ],
    command: crateTests("licoup-application"),
  }),
  defineModule({
    id: "rust.crate.endpoint-core",
    kind: "rust-crate",
    summary: "Fixed-SDK endpoint ports, authority facts, and protocol and credential recovery contract",
    inputs: [
      "crates/licoup-endpoint-core/**",
    ],
    command: crateTests("licoup-endpoint-core"),
  }),
  defineModule({
    id: "rust.crate.extension-contracts",
    kind: "rust-crate",
    summary: "Open extension profiles, package manifests, credential scopes, and schema agreement",
    inputs: [
      "crates/licoup-extension-contracts/**",
      "schemas/extensions/**",
    ],
    command: command("cargo", [
      "test",
      "--locked",
      "--manifest-path",
      "crates/licoup-extension-contracts/Cargo.toml",
    ], 10 * 60_000),
  }),
  defineModule({
    id: "rust.crate.migrate",
    kind: "rust-crate",
    summary: "Standalone migration tool over the client's own migration frontier and store-owner facts",
    inputs: [
      "crates/licoup-migrate/**",
    ],
    command: crateTests("licoup-migrate"),
  }),
  defineModule({
    id: "rust.crate.protocol-bindings",
    kind: "rust-crate",
    summary: "Endpoint protocol revision, admission, and inbound message bindings",
    inputs: [
      "crates/licoup-protocol-bindings/**",
    ],
    command: crateTests("licoup-protocol-bindings"),
  }),
]);
