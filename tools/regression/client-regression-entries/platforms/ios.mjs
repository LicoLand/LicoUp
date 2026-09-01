import { definePlatformEntry, readOnlyCommandOutput } from "../factory.mjs";
export default definePlatformEntry({
  id: "ios",
  hosts: ["darwin"],
  tools: ["flutter", "xcrun"],
  async capabilityProbe() {
    const devices = await readOnlyCommandOutput("xcrun", [
      "simctl", "list", "devices", "booted", "--json",
    ]);
    if (!devices.ok) return { eligible: false, reason: "ios_simulator_unavailable" };
    try {
      const parsed = JSON.parse(devices.output);
      const booted = Object.values(parsed?.devices || {}).flat()
        .some((device) => device?.state === "Booted");
      return booted
        ? { eligible: true, reason: null }
        : { eligible: false, reason: "ios_simulator_unavailable" };
    } catch {
      return { eligible: false, reason: "ios_simulator_unavailable" };
    }
  },
  liveCommand: Object.freeze({ program: "node", args: Object.freeze([
    "tools/scripts/client-mobile-simulator-closure.mjs", "--platform", "ios",
  ]), cwd: ".", timeoutMs: 30 * 60_000 }),
});
