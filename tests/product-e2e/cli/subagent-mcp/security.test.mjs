import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const supervisor = readFileSync(
  "crates/licoup-native/src/platform/subagent_mcp_supervisor.rs",
  "utf8",
);
const connector = readFileSync(
  "crates/licoup-native/src/bin/lico-subagent-mcp.rs",
  "utf8",
);

test("service is bounded authenticated loopback with private discovery", () => {
  assert.match(supervisor, /Ipv4Addr::LOCALHOST/u);
  assert.match(supervisor, /constant_time_eq/u);
  assert.match(supervisor, /Bearer /u);
  assert.match(supervisor, /MAX_HTTP_CONNECTIONS: usize = 32/u);
  assert.match(supervisor, /MAX_SESSIONS: usize = 64/u);
  assert.match(supervisor, /MAX_TOOL_WORKERS: usize = 8/u);
  assert.match(supervisor, /atomic_write_private_text_bounded/u);
  assert.match(supervisor, /impl Drop for SubagentMcpSupervisor/u);
});

test("connector contains no tools and performs no ambiguous retry", () => {
  assert.doesNotMatch(connector, /lico_subagent_|lico_assistant_/u);
  assert.doesNotMatch(connector, /retry|sleep/u);
  assert.match(connector, /connector_exchange/u);
  assert.match(connector, /session_id/u);
  assert.match(connector, /impl Drop for ConnectorSession/u);
  assert.match(connector, /202 if response\.is_empty/u);
});
