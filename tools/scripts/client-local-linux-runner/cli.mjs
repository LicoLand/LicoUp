import { knownLanes } from "./constants.mjs";

function invalid(message) {
  throw new Error(`client_local_linux_runner_usage:${message}`);
}

export function parseArgs(argv) {
  const [command, ...rest] = argv;
  if (command === "self-test" || command === "inspect") {
    if (rest.length !== 0) invalid(`${command}_takes_no_arguments`);
    return Object.freeze({ command, lane: null });
  }
  if (command !== "run") invalid("expected_inspect_run_or_self_test");
  if (rest.length !== 2) invalid("run_requires_lane_or_profile");
  if (rest[0] === "--profile" && rest[1] === "engineering") {
    return Object.freeze({ command, lane: null, profile: "engineering" });
  }
  if (rest[0] !== "--lane" || !knownLanes.includes(rest[1])) {
    invalid("run_requires_known_lane_or_profile");
  }
  return Object.freeze({ command, lane: rest[1], profile: null });
}
