import { existsSync } from "node:fs";
import { spawn } from "node:child_process";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

export const regressionRoot = path.resolve(fileURLToPath(new URL("../../..", import.meta.url)));

function executableCandidates(name) {
  const suffixes = process.platform === "win32" ? [".exe", ".cmd", ".bat", ""] : [""];
  return String(process.env.PATH || "")
    .split(path.delimiter)
    .filter(Boolean)
    .flatMap((directory) => suffixes.map((suffix) => path.join(directory, `${name}${suffix}`)));
}

export function commandAvailable(name) {
  return executableCandidates(name).some((candidate) => existsSync(candidate));
}

export async function readOnlyCommandOutput(program, args) {
  return new Promise((resolve) => {
    let output = "";
    let overflow = false;
    let settled = false;
    const finish = (value) => {
      if (settled) return;
      settled = true;
      resolve(value);
    };
    let child;
    try {
      child = spawn(program, args, {
        cwd: regressionRoot,
        env: process.env,
        shell: false,
        stdio: ["ignore", "pipe", "ignore"],
        windowsHide: true,
      });
    } catch {
      finish(Object.freeze({ ok: false, output: "" }));
      return;
    }
    child.once("error", () => finish(Object.freeze({ ok: false, output: "" })));
    child.stdout.on("data", (chunk) => {
      if (overflow) return;
      output += chunk.toString("utf8");
      if (output.length > 1024 * 1024) {
        output = "";
        overflow = true;
      }
    });
    child.once("close", (code) => finish(Object.freeze({
      ok: code === 0 && !overflow,
      output: code === 0 && !overflow ? output : "",
    })));
  });
}

export function definePlatformEntry({ id, hosts, tools = [], artifacts = [], liveCommand = null,
  resources = [], inputs = [], unverifiedInputs = [],
  unavailableReason = "platform_runtime_unavailable", capabilityProbe = null }) {
  return Object.freeze({
    id,
    kind: "platform",
    stage: "compatibility",
    lane: `platform:${id}`,
    // Different platform branches must not serialize behind one synthetic
    // device lock. A concrete platform still has one exclusive runtime lane.
    resources: Object.freeze([`platform-runtime:${id}`, ...resources]),
    inputs: Object.freeze([...inputs]),
    unverifiedInputs: Object.freeze([...unverifiedInputs]),
    liveCommand,
    async probe() {
      if (hosts.length > 0 && !hosts.includes(process.platform)) {
        return Object.freeze({ eligible: false, reason: "platform_host_unavailable" });
      }
      if (tools.some((tool) => !commandAvailable(tool))) {
        return Object.freeze({ eligible: false, reason: "platform_toolchain_unavailable" });
      }
      if (artifacts.some((artifact) => !existsSync(path.resolve(regressionRoot, artifact)))) {
        return Object.freeze({ eligible: false, reason: unavailableReason });
      }
      if (!liveCommand) {
        return Object.freeze({ eligible: false, reason: "platform_live_verifier_unavailable" });
      }
      if (capabilityProbe) {
        const capability = await capabilityProbe();
        if (!capability.eligible) return Object.freeze(capability);
      }
      return Object.freeze({ eligible: true, reason: null });
    },
  });
}
