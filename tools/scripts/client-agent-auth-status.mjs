#!/usr/bin/env node

import { runAgentAuthStatusCli } from "./client-agent-auth-status/run.mjs";

await runAgentAuthStatusCli(process.argv.slice(2));
