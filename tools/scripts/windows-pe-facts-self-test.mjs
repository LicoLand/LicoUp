#!/usr/bin/env node
import { inspectWindowsPeBytes, WINDOWS_PE_MACHINE } from "./lib/windows-pe-facts.mjs";

function fixture(machine) {
  const bytes = Buffer.alloc(512);
  bytes.write("MZ", 0, "ascii");
  bytes.writeUInt32LE(128, 0x3c);
  bytes.write("PE\0\0", 128, "binary");
  bytes.writeUInt16LE(machine, 132);
  bytes.writeUInt16LE(240, 148);
  bytes.writeUInt16LE(0x20b, 152);
  return bytes;
}

function rejected(bytes) {
  try {
    inspectWindowsPeBytes(bytes);
    return false;
  } catch {
    return true;
  }
}

for (const [architecture, machine] of Object.entries(WINDOWS_PE_MACHINE)) {
  const facts = inspectWindowsPeBytes(fixture(machine));
  if (facts.architecture !== architecture || facts.format !== "PE32+") {
    throw new Error("windows_pe_valid_fixture_rejected");
  }
}
if (!rejected(Buffer.alloc(16)) ||
    !rejected(fixture(0x014c)) ||
    !rejected(Buffer.from(fixture(WINDOWS_PE_MACHINE.x64).fill(0, 128, 132)))) {
  throw new Error("windows_pe_negative_fixture_accepted");
}
console.log(JSON.stringify({ ok: true, caseCount: 5 }));
