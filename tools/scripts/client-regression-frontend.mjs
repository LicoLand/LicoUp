#!/usr/bin/env node
import process from "node:process";
import { main } from "./client-module-regression.mjs";

process.exitCode = await main(["--lane", "frontend", ...process.argv.slice(2)]);
