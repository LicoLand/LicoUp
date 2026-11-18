import os from "node:os";
import path from "node:path";
import process from "node:process";

function defaultCacheRoot(env = process.env) {
  if (process.platform === "darwin") {
    return path.join(os.homedir(), "Library", "Caches", "LicoUp", "client-toolchain");
  }
  if (process.platform === "win32") {
    return path.join(
      env.LOCALAPPDATA || path.join(os.homedir(), "AppData", "Local"),
      "LicoUp",
      "ClientToolchain"
    );
  }
  return path.join(env.XDG_CACHE_HOME || path.join(os.homedir(), ".cache"), "licoup", "client-toolchain");
}

export function clientCacheRoot(env = process.env) {
  return path.resolve(env.LICO_CLIENT_CACHE_ROOT || defaultCacheRoot(env));
}

export function clientPubCacheRoot(env = process.env) {
  return path.resolve(env.LICO_CLIENT_PUB_CACHE || env.PUB_CACHE || path.join(clientCacheRoot(env), "pub-cache"));
}

export function defaultSystemPubCacheRoot(env = process.env) {
  if (process.platform === "win32") {
    return path.resolve(env.LOCALAPPDATA || path.join(os.homedir(), "AppData", "Local"), "Pub", "Cache");
  }
  return path.resolve(os.homedir(), ".pub-cache");
}

const LOOPBACK_PROXY_EXEMPTIONS = Object.freeze(["localhost", "127.0.0.1", "::1"]);

function mergeLoopbackProxyExemptions(current) {
  const parts = String(current ?? "")
    .split(/[\s,]+/u)
    .map((part) => part.trim())
    .filter(Boolean);
  const seen = new Set(parts.map((part) => part.toLowerCase()));
  for (const extra of LOOPBACK_PROXY_EXEMPTIONS) {
    if (!seen.has(extra.toLowerCase())) {
      parts.push(extra);
      seen.add(extra.toLowerCase());
    }
  }
  return parts.join(",");
}

export function withTestProcessLoopbackProxyExemption(env = process.env) {
  const nextEnv = { ...env };
  const upper = nextEnv.NO_PROXY;
  const lower = nextEnv.no_proxy;
  if (upper != null && lower == null) {
    const merged = mergeLoopbackProxyExemptions(upper);
    nextEnv.NO_PROXY = merged;
    nextEnv.no_proxy = merged;
  } else if (lower != null && upper == null) {
    const merged = mergeLoopbackProxyExemptions(lower);
    nextEnv.NO_PROXY = merged;
    nextEnv.no_proxy = merged;
  } else {
    nextEnv.NO_PROXY = mergeLoopbackProxyExemptions(upper);
    nextEnv.no_proxy = mergeLoopbackProxyExemptions(lower);
  }
  return nextEnv;
}

export function withClientToolchainEnv(env = process.env, options = {}) {
  const nextEnv = {
    ...withTestProcessLoopbackProxyExemption(env),
    PUB_CACHE: path.resolve(options.pubCache || clientPubCacheRoot(env))
  };
  if (options.pubHostedUrl) {
    nextEnv.PUB_HOSTED_URL = options.pubHostedUrl;
  } else if (env.LICO_CLIENT_PUB_HOSTED_URL) {
    nextEnv.PUB_HOSTED_URL = env.LICO_CLIENT_PUB_HOSTED_URL;
  }
  if (env.LICO_FLUTTER_STORAGE_BASE_URL) {
    nextEnv.FLUTTER_STORAGE_BASE_URL = env.LICO_FLUTTER_STORAGE_BASE_URL;
  }
  return nextEnv;
}
