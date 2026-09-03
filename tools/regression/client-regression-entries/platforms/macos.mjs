import { definePlatformEntry } from "../factory.mjs";
export default definePlatformEntry({
  id: "macos",
  hosts: ["darwin"],
  tools: ["xcrun", "flutter"],
  resources: ["agent-runtime:codex"],
  artifacts: ["build/apps/desktop/runnable/macos/release/LicoUp.app"],
  liveCommand: Object.freeze({ program: "node", args: Object.freeze([
    "tools/scripts/client-device-demo.mjs", "--platform", "macos",
  ]), cwd: ".", timeoutMs: 30 * 60_000 }),
});
