#!/usr/bin/env node

// Operator-facing diagnosis and a single-step repair for client-state
// migration. Startup migration stays exclusively with the Rust admission in
// `crates/licoup-native/src/domain/client_state_migration.rs`; this tool reads
// the same ledger, probes the same durable shapes and never replaces it.
// Conversion of a whole data root belongs to the standalone `licoup-migrate`
// tool, which is a different artifact with its own release.

import { runClientStateMigrationCli } from "./client-state-migration/cli.mjs";

runClientStateMigrationCli();
