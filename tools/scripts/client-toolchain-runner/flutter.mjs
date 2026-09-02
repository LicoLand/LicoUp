import {
  existsSync,
  mkdirSync,
  readFileSync,
  statSync,
  symlinkSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import path from "node:path";
import process from "node:process";
import {
  clientPubCacheRoot,
  seedClientGradleHome,
  withClientToolchainEnv,
} from "../client-toolchain-env.mjs";
import { FLUTTER_GENERATED_PLUGIN_FILES, ROOT } from "./constants.mjs";
import { preferredPubHostedUrl, seedStablePubCache } from "./pub-cache.mjs";
import { run } from "./process.mjs";

export function flutterEnv(projectRoot) {
  const pubCache = clientPubCacheRoot();
  mkdirSync(pubCache, { recursive: true });
  return withClientToolchainEnv(process.env, {
    pubCache,
    pubHostedUrl: preferredPubHostedUrl(projectRoot)
  });
}

export function isFlutterCommand(command) {
  const basename = path.basename(command).toLowerCase();
  return basename === "flutter" || basename === "flutter.bat" || basename === "flutter.cmd" || basename === "flutter.exe";
}

export function isFlutterPubGet(args) {
  return args[0] === "pub" && args[1] === "get";
}

export function shouldPrepareFlutterDependencies(args) {
  return args[0] === "analyze" || args[0] === "test" || args[0] === "run" || args[0] === "build";
}

export function shouldPrepareGradleDependencies(args) {
  if (args[0] === "run") {
    return true;
  }
  return args[0] === "build" && ["apk", "appbundle", "aar"].includes(args[1]);
}

export function withNoImplicitPub(args) {
  if (!shouldPrepareFlutterDependencies(args) || args.includes("--no-pub")) {
    return args;
  }
  if (args[0] === "build" && args.length > 1) {
    return [args[0], args[1], "--no-pub", ...args.slice(2)];
  }
  return [args[0], "--no-pub", ...args.slice(1)];
}

export function withEnforcedLockfile(args) {
  if (!isFlutterPubGet(args) || args.includes("--enforce-lockfile")) {
    return args;
  }
  return [...args, "--enforce-lockfile"];
}

export function desktopPluginLinkRoot(projectRoot, platform) {
  return path.join(projectRoot, platform, "flutter", "ephemeral", ".plugin_symlinks");
}

export function createDesktopPluginJunctions(projectRoot) {
  const dependenciesPath = path.join(projectRoot, ".flutter-plugins-dependencies");
  if (!existsSync(dependenciesPath)) {
    return 0;
  }
  const dependencies = JSON.parse(readFileSync(dependenciesPath, "utf8"));
  let created = 0;
  for (const platform of ["windows", "linux"]) {
    const platformRoot = path.join(projectRoot, platform);
    const plugins = dependencies.plugins?.[platform] || [];
    if (!existsSync(platformRoot) || plugins.length === 0) {
      continue;
    }
    const linkRoot = desktopPluginLinkRoot(projectRoot, platform);
    mkdirSync(linkRoot, { recursive: true });
    for (const plugin of plugins) {
      if (!plugin?.name || !plugin?.path) {
        continue;
      }
      const target = path.resolve(plugin.path);
      if (!existsSync(target) || !statSync(target).isDirectory()) {
        continue;
      }
      const link = path.join(linkRoot, plugin.name);
      if (existsSync(link)) {
        continue;
      }
      symlinkSync(target, link, "junction");
      created += 1;
    }
  }
  return created;
}

export async function runFlutterPubGet(projectRoot, env, { offline }) {
  const args = ["pub", "get", "--enforce-lockfile", ...(offline ? ["--offline"] : [])];
  try {
    await run("flutter", args, { cwd: projectRoot, env });
  } catch (error) {
    if (process.platform !== "win32") {
      throw error;
    }
    const created = createDesktopPluginJunctions(projectRoot);
    if (created === 0) {
      throw error;
    }
    console.warn(`[client-toolchain-runner] Created ${created} Flutter plugin junction(s); retrying pub get.`);
    await run("flutter", args, { cwd: projectRoot, env });
  }
}

export function snapshotFlutterGeneratedPluginFiles(projectRoot) {
  return FLUTTER_GENERATED_PLUGIN_FILES.map((relativePath) => {
    const absolutePath = path.join(projectRoot, relativePath);
    return {
      absolutePath,
      exists: existsSync(absolutePath),
      content: existsSync(absolutePath) ? readFileSync(absolutePath) : null
    };
  });
}

export function restoreFlutterGeneratedPluginFiles(snapshot) {
  for (const item of snapshot) {
    if (item.exists) {
      writeFileSync(item.absolutePath, item.content);
    } else if (existsSync(item.absolutePath)) {
      unlinkSync(item.absolutePath);
    }
  }
}

export async function prepareFlutterCommand(command, args, cwd) {
  if (!isFlutterCommand(command) || !existsSync(path.join(cwd, "pubspec.yaml"))) {
    return { command, args, env: process.env };
  }
  const env = flutterEnv(cwd);
  seedStablePubCache(cwd, env);
  if (shouldPrepareGradleDependencies(args)) {
    seedClientGradleHome(env, { log: (message) => console.log(message) });
  }
  if (shouldPrepareFlutterDependencies(args)) {
    const generatedPluginSnapshot = snapshotFlutterGeneratedPluginFiles(cwd);
    try {
      await runFlutterPubGet(cwd, env, { offline: true });
    } finally {
      restoreFlutterGeneratedPluginFiles(generatedPluginSnapshot);
    }
    return { command, args: withNoImplicitPub(args), env };
  }
  return { command, args: withEnforcedLockfile(args), env };
}

export async function runPreparedCommand(prepared, cwd) {
  try {
    await run(prepared.command, prepared.args, { cwd, env: prepared.env });
    return;
  } catch (error) {
    if (!isFlutterCommand(prepared.command) ||
      !isFlutterPubGet(prepared.args) ||
      prepared.args.includes("--offline")) {
      throw error;
    }
    const offlineArgs = [...prepared.args, "--offline"];
    const offlineEnv = { ...prepared.env };
    delete offlineEnv.PUB_HOSTED_URL;
    console.warn("[client-toolchain-runner] Online flutter pub get failed; retrying with the locked local cache.");
    await run(prepared.command, offlineArgs, { cwd, env: offlineEnv });
  }
}
