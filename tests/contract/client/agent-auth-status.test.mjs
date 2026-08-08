import assert from "node:assert/strict";
import test from "node:test";
import {
  collectAgentAuthStatus,
  loadCanonicalAgentManifests,
  loadProbeRegistry,
  parseArguments,
  runAgentAuthStatusCli,
  runSyntheticSelfTest,
  validateProbeRegistry,
} from "../../../tools/scripts/client-agent-auth-status/run.mjs";
import { defaultMaxStdoutBytes } from "../../../tools/scripts/client-agent-auth-status/probe.mjs";

const canonicalAgentIds = Object.freeze([
  "antigravity",
  "claude-code",
  "codex",
  "copilot",
  "cursor",
  "hermes",
  "kilo-code",
  "kimi-code",
  "openclaw",
  "opencode",
  "pi",
]);

const manifests = [
  {
    identity: { agentId: "probeable" },
    configuration: { binaryEnvironmentKeys: ["PROBEABLE_BIN"] },
  },
  {
    identity: { agentId: "unprobeable" },
    configuration: { binaryEnvironmentKeys: [] },
  },
];

const registry = {
  schemaVersion: "lico.agent-auth-probes.v1",
  probes: {
    probeable: {
      kind: "exit-status",
      executable: "probeable",
      arguments: ["auth", "status"],
      authenticatedExitCodes: [0],
      unauthenticatedExitCodes: [1],
      authenticatedStdoutPrefixes: [],
      unauthenticatedStdoutPrefixes: [],
    },
  },
};

test("generic authentication probe distinguishes verified states and skips unavailable agents", async () => {
  const authenticated = await collectAgentAuthStatus(
    { agents: [], timeoutMs: 1_000 },
    { manifests, registry, execute: async () => ({ kind: "exit", code: 0 }) },
  );
  assert.deepEqual(authenticated.agents, [
    {
      agentId: "probeable",
      probeSupported: true,
      authenticationStatus: "authenticated",
      reasonCode: "probe_confirmed",
    },
    {
      agentId: "unprobeable",
      probeSupported: false,
      authenticationStatus: "skipped",
      reasonCode: "probe_unavailable",
    },
  ]);

  const unauthenticated = await collectAgentAuthStatus(
    { agents: ["probeable"], timeoutMs: 1_000 },
    { manifests, registry, execute: async () => ({ kind: "exit", code: 1 }) },
  );
  assert.deepEqual(unauthenticated.agents, [{
    agentId: "probeable",
    probeSupported: true,
    authenticationStatus: "unauthenticated",
    reasonCode: "probe_rejected",
  }]);
});

test("unverifiable, missing, timeout, signal, and unknown output outcomes are skipped", async () => {
  const cases = [
    [{ kind: "exit", code: 2 }, "probe_inconclusive"],
    [{ kind: "timeout" }, "probe_timeout"],
    [{ kind: "signal", signal: true }, "probe_inconclusive"],
    [{ kind: "start-failed" }, "executable_unavailable"],
    [{ kind: "output-limit" }, "probe_output_limit"],
    [{ kind: "output", stdout: "unknown-output" }, "probe_inconclusive"],
  ];
  for (const [outcome, expectedReasonCode] of cases) {
    const receipt = await collectAgentAuthStatus(
      { agents: ["probeable"], timeoutMs: 1_000 },
      { manifests, registry, execute: async () => outcome },
    );
    assert.deepEqual(receipt.agents, [{
      agentId: "probeable",
      probeSupported: false,
      authenticationStatus: "skipped",
      reasonCode: expectedReasonCode,
    }]);
  }

  const unavailable = await collectAgentAuthStatus(
    { agents: ["unprobeable"], timeoutMs: 1_000 },
    { manifests, registry, execute: async () => assert.fail("unavailable probe executed") },
  );
  assert.deepEqual(unavailable.agents, [{
    agentId: "unprobeable",
    probeSupported: false,
    authenticationStatus: "skipped",
    reasonCode: "probe_unavailable",
  }]);
});

test("fixed output evidence prevents exit-code-only authentication claims", async () => {
  const outputRegistry = {
    schemaVersion: "lico.agent-auth-probes.v1",
    probes: {
      probeable: {
        ...registry.probes.probeable,
        authenticatedStdoutPrefixes: ["Authenticated"],
        unauthenticatedStdoutPrefixes: ["Not authenticated"],
      },
    },
  };
  for (const [outcome, expected] of [
    [{ kind: "exit", code: 0, stdout: "Authenticated" }, "authenticated"],
    [{ kind: "exit", code: 1, stdout: "Not authenticated" }, "unauthenticated"],
    [{ kind: "exit", code: 0, stdout: "unknown" }, "skipped"],
    [{ kind: "exit", code: 1, stdout: "unknown" }, "skipped"],
  ]) {
    const receipt = await collectAgentAuthStatus(
      { agents: ["probeable"], timeoutMs: 1_000 },
      { manifests, registry: outputRegistry, execute: async () => outcome },
    );
    assert.equal(receipt.agents[0].authenticationStatus, expected);
  }
});

test("probe execution uses only the fixed command and inherited environment", async () => {
  const environment = Object.freeze({
    PROBEABLE_BIN: "/synthetic/private-path-canary/probeable",
    SYNTHETIC_PARENT_VALUE: "inherited-environment-canary",
  });
  const invocations = [];
  const receipt = await collectAgentAuthStatus(
    { agents: ["probeable"], timeoutMs: 1_234 },
    {
      manifests,
      registry,
      environment,
      execute: async (executable, args, options) => {
        invocations.push({ executable, args, options });
        return { kind: "exit", code: 0 };
      },
    },
  );

  assert.equal(invocations.length, 1);
  assert.equal(invocations[0].executable, environment.PROBEABLE_BIN);
  assert.deepEqual(invocations[0].args, ["auth", "status"]);
  assert.equal(invocations[0].options.environment, environment);
  assert.equal(invocations[0].options.timeoutMs, 1_234);
  assert.equal(invocations[0].options.maxStdoutBytes, 8 * 1024);
  assert.equal(invocations[0].options.maxStdoutBytes, defaultMaxStdoutBytes);
  assert.equal(receipt.agents[0].authenticationStatus, "authenticated");
});

test("probe execution inherits the default process environment", async () => {
  let observedEnvironment;
  await collectAgentAuthStatus(
    { agents: ["probeable"], timeoutMs: 2_345 },
    {
      manifests,
      registry,
      execute: async (_executable, _args, options) => {
        observedEnvironment = options.environment;
        assert.equal(options.timeoutMs, 2_345);
        assert.equal(options.maxStdoutBytes, 8 * 1024);
        return { kind: "exit", code: 0 };
      },
    },
  );
  assert.equal(observedEnvironment, process.env);
});

test("authentication probes execute strictly sequentially", async () => {
  const sequentialManifests = [
    { identity: { agentId: "first" }, configuration: { binaryEnvironmentKeys: [] } },
    { identity: { agentId: "second" }, configuration: { binaryEnvironmentKeys: [] } },
  ];
  const sequentialRegistry = {
    schemaVersion: "lico.agent-auth-probes.v1",
    probes: {
      first: { ...registry.probes.probeable, executable: "first" },
      second: { ...registry.probes.probeable, executable: "second" },
    },
  };
  let releaseFirst;
  const firstDeferred = new Promise((resolve) => { releaseFirst = resolve; });
  const calls = [];
  const pending = collectAgentAuthStatus(
    { agents: [], timeoutMs: 1_000 },
    {
      manifests: sequentialManifests,
      registry: sequentialRegistry,
      execute: async (executable) => {
        calls.push(executable);
        if (executable === "first") await firstDeferred;
        return { kind: "exit", code: 0 };
      },
    },
  );

  await Promise.resolve();
  assert.deepEqual(calls, ["first"]);
  releaseFirst();
  const receipt = await pending;
  assert.deepEqual(calls, ["first", "second"]);
  assert.deepEqual(receipt.agents.map((agent) => agent.agentId), ["first", "second"]);
});

test("probe receipts never project command output, account, credential, or path canaries", async () => {
  const privateCanaries = Object.freeze([
    "synthetic-account@example.invalid",
    "synthetic-credential-canary",
    "/synthetic/private-path-canary",
  ]);
  const receipt = await collectAgentAuthStatus(
    { agents: ["probeable"], timeoutMs: 1_000 },
    {
      manifests,
      registry,
      execute: async () => ({
        kind: "exit",
        code: 0,
        stdout: privateCanaries.join(" "),
        stderr: privateCanaries.join(" "),
        account: privateCanaries[0],
        credential: privateCanaries[1],
        path: privateCanaries[2],
      }),
    },
  );
  const serialized = JSON.stringify(receipt);

  assert.equal(receipt.agents[0].authenticationStatus, "authenticated");
  for (const canary of privateCanaries) assert.equal(serialized.includes(canary), false);
  for (const forbiddenField of ["stdout", "stderr", "account", "credential", "path"]) {
    assert.equal(serialized.includes(`\"${forbiddenField}\"`), false);
  }
});

test("canonical inventory is fully covered once in stable agent-id order", async () => {
  const canonicalManifests = loadCanonicalAgentManifests();
  assert.deepEqual(
    canonicalManifests.map((manifest) => manifest.identity.agentId),
    canonicalAgentIds,
  );

  const receipt = await collectAgentAuthStatus(
    { agents: [], timeoutMs: 1_000 },
    {
      manifests: canonicalManifests,
      registry: { schemaVersion: "lico.agent-auth-probes.v1", probes: {} },
      execute: async () => assert.fail("unregistered canonical probe executed"),
    },
  );
  assert.deepEqual(receipt.agents.map((agent) => agent.agentId), canonicalAgentIds);
  assert.equal(new Set(receipt.agents.map((agent) => agent.agentId)).size, canonicalAgentIds.length);
  assert.ok(receipt.agents.every((agent) => (
    agent.authenticationStatus === "skipped"
      && agent.reasonCode === "probe_unavailable"
  )));
});

test("real probe registry locks supported commands and skips every other canonical agent", async () => {
  const canonicalManifests = loadCanonicalAgentManifests();
  const realRegistry = loadProbeRegistry(new Set(canonicalAgentIds));
  assert.deepEqual(Object.keys(realRegistry.probes).sort(), ["claude-code", "codex"]);
  assert.deepEqual(realRegistry.probes["claude-code"], {
    kind: "exit-status",
    executable: "claude",
    arguments: ["auth", "status"],
    authenticatedExitCodes: [0],
    unauthenticatedExitCodes: [1],
    authenticatedStdoutPrefixes: [],
    unauthenticatedStdoutPrefixes: [],
  });
  assert.deepEqual(realRegistry.probes.codex, {
    kind: "exit-status",
    executable: "codex",
    arguments: ["login", "status"],
    authenticatedExitCodes: [0],
    unauthenticatedExitCodes: [1],
    authenticatedStdoutPrefixes: [
      "Logged in using ChatGPT",
      "Logged in using an API key",
      "Logged in using Agent Identity",
    ],
    unauthenticatedStdoutPrefixes: ["Not logged in"],
  });

  const calls = [];
  const receipt = await collectAgentAuthStatus(
    { agents: [], timeoutMs: 1_000 },
    {
      manifests: canonicalManifests,
      registry: realRegistry,
      execute: async (executable, arguments_) => {
        calls.push([executable, arguments_]);
        return executable === "codex"
          ? { kind: "exit", code: 0, stdout: "Logged in using ChatGPT" }
          : { kind: "exit", code: 0 };
      },
    },
  );
  assert.deepEqual(calls, [
    ["claude", ["auth", "status"]],
    ["codex", ["login", "status"]],
  ]);
  for (const agent of receipt.agents) {
    if (agent.agentId === "claude-code" || agent.agentId === "codex") {
      assert.equal(agent.authenticationStatus, "authenticated");
    } else {
      assert.equal(agent.authenticationStatus, "skipped");
      assert.equal(agent.reasonCode, "probe_unavailable");
    }
  }
});

test("registry rejects unknown agents and overlapping exit statuses", () => {
  assert.throws(
    () => validateProbeRegistry(registry, new Set(["different"])),
    /auth_probe_agent_unknown/u,
  );
  assert.throws(
    () => validateProbeRegistry({
      ...registry,
      probes: {
        probeable: {
          ...registry.probes.probeable,
          unauthenticatedExitCodes: [0],
        },
      },
    }, new Set(["probeable"])),
    /auth_probe_exit_code_overlap/u,
  );
  assert.throws(
    () => validateProbeRegistry({
      ...registry,
      probes: {
        probeable: {
          ...registry.probes.probeable,
          unauthenticatedStdoutPrefixes: ["Not logged in"],
        },
      },
    }, new Set(["probeable"])),
    /auth_probe_output_evidence_asymmetric/u,
  );

  for (const [authenticatedStdoutPrefixes, unauthenticatedStdoutPrefixes] of [
    [["Logged in"], ["Logged in"]],
    [["Logged in"], ["Logged in using ChatGPT"]],
    [["Not authenticated now"], ["Not authenticated"]],
  ]) {
    assert.throws(
      () => validateProbeRegistry({
        ...registry,
        probes: {
          probeable: {
            ...registry.probes.probeable,
            authenticatedStdoutPrefixes,
            unauthenticatedStdoutPrefixes,
          },
        },
      }, new Set(["probeable"])),
      /auth_probe_output_prefix_overlap/u,
    );
  }
});

test("conflicting exit and output evidence is always skipped", async () => {
  const outputRegistry = {
    schemaVersion: "lico.agent-auth-probes.v1",
    probes: {
      probeable: {
        ...registry.probes.probeable,
        authenticatedStdoutPrefixes: ["Logged in"],
        unauthenticatedStdoutPrefixes: ["Not logged in"],
      },
    },
  };
  for (const outcome of [
    { kind: "exit", code: 0, stdout: "Not logged in" },
    { kind: "exit", code: 1, stdout: "Logged in" },
    { kind: "exit", code: 0, stdout: "Logged in but session expired" },
    { kind: "exit", code: 0, stdout: "Logged in\nNot logged in" },
    { kind: "exit", code: 1, stdout: "Logged in\nNot logged in" },
  ]) {
    const receipt = await collectAgentAuthStatus(
      { agents: ["probeable"], timeoutMs: 1_000 },
      { manifests, registry: outputRegistry, execute: async () => outcome },
    );
    assert.equal(receipt.agents[0].authenticationStatus, "skipped");
    assert.equal(receipt.agents[0].reasonCode, "probe_inconclusive");
  }
});

test("CLI boundary redacts private probe evidence and thrown errors", async () => {
  const canaries = [
    "synthetic-account@example.invalid",
    "synthetic-credential-canary",
    "/synthetic/private-path-canary",
  ];
  const outcomes = [
    { kind: "exit", code: 0, stdout: canaries.join(" "), stderr: canaries.join(" ") },
    { kind: "output", stdout: canaries.join(" "), account: canaries[0] },
    { kind: "output-limit", credential: canaries[1] },
    { kind: "start-failed", path: canaries[2] },
  ];
  for (const outcome of outcomes) {
    let output = "";
    let exitCode;
    await runAgentAuthStatusCli([], {
      collect: () => collectAgentAuthStatus(
        { agents: ["probeable"], timeoutMs: 1_000 },
        { manifests, registry, execute: async () => outcome },
      ),
      write: (value) => { output += value; },
      setExitCode: (value) => { exitCode = value; },
    });
    assert.equal(exitCode, undefined);
    assert.doesNotThrow(() => JSON.parse(output));
    for (const canary of canaries) assert.equal(output.includes(canary), false);
  }

  let errorOutput = "";
  let errorExitCode;
  await runAgentAuthStatusCli([], {
    collect: async () => { throw new Error(canaries.join(" ")); },
    write: (value) => { errorOutput += value; },
    setExitCode: (value) => { errorExitCode = value; },
  });
  assert.equal(errorExitCode, 1);
  assert.deepEqual(JSON.parse(errorOutput), {
    schemaVersion: "lico.agent-auth-status-error.v1",
    status: "failed",
    errorCode: "auth_probe_failed",
  });
  for (const canary of canaries) assert.equal(errorOutput.includes(canary), false);
});

test("CLI parsing is bounded and self-test never reads real authentication", async () => {
  assert.deepEqual(parseArguments(["--agent", "KimiCode", "--timeout-ms", "1000"]), {
    agents: ["kimi-code"],
    selfTest: false,
    timeoutMs: 1_000,
  });
  assert.deepEqual(await runSyntheticSelfTest(), {
    schemaVersion: "lico.agent-auth-status-self-test.v1",
    status: "passed",
    checks: 4,
  });
});
