import path from "node:path";
import { fileURLToPath } from "node:url";

export const repoRoot = path.resolve(fileURLToPath(new URL("../../..", import.meta.url)));
export const dockerfileRef = "apps/desktop/docker/ubuntu-client.Dockerfile";
export const dockerfilePath = path.join(repoRoot, ...dockerfileRef.split("/"));
export const runnerPlatform = "linux/amd64";
export const runnerArchitecture = "x86_64";
export const supportedLanes = Object.freeze([
  "source",
  "flutter",
  "rust",
  "android",
  "dependencies",
]);
export const knownLanes = supportedLanes;
export const buildRoot = path.join(repoRoot, "build");
export const runnerRoot = path.join(buildRoot, "local-linux-ci");
export const reportRoot = path.join(buildRoot, "reports");
export const reportSchemaVersion = "licoup.client-local-linux-ci.v1";
