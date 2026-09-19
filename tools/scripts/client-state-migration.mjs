#!/usr/bin/env node

// Operator-facing diagnosis and a single-step repair for client-state
// migration. Startup migration stays exclusively with the Rust admission in
// `crates/licoup-native/src/domain/client_state_migration.rs`; this tool reads
// the same ledger, probes the same durable shapes and never replaces it.
// The independently distributed migration package planned for
// `tools/data-migration/` is a different artifact with its own release.

import { runClientStateMigrationCli } from "./client-state-migration/cli.mjs";

runClientStateMigrationCli();
