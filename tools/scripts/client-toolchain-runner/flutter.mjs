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
import { androidJavaEnvironment } from "../lib/android-apk-facts/sdk.mjs";
import {
  createFlutterJsonStatsCollector,
  hasFlutterTestReporter,
  withFlutterJsonReporter,
} from "../../regression/client-regression-toolchain-stats/flutter.mjs";
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

export function prepareFlutterTestReporting(args) {
  const capture = args[0] === "test" && !hasFlutterTestReporter(args);
  return Object.freeze({
    capture,
    args: capture ? Object.freeze(withFlutterJsonReporter(args)) : args,
  });
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
  if (["gradlew", "gradlew.bat"].includes(path.basename(command).toLowerCase())) {
    const java = androidJavaEnvironment();
    return { command, args, env: { ...process.env, JAVA_HOME: java.env.JAVA_HOME } };
  }
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
    const reporting = prepareFlutterTestReporting(withNoImplicitPub(args));
    return {
      command,
      args: reporting.args,
      env,
      captureFlutterTestOutput: reporting.capture,
    };
  }
  return { command, args: withEnforcedLockfile(args), env };
}

function measuredMetric(metrics, key) {
  return metrics?.[key]?.status === "measured" ? metrics[key].value : null;
}

async function runFlutterTestWithSafeDiagnostics(prepared, cwd) {
  const collector = createFlutterJsonStatsCollector({ repoRoot: ROOT, commandCwd: cwd });
  let failure = null;
  try {
    await run(prepared.command, prepared.args, {
      cwd,
      env: prepared.env,
      onStdout: collector.push,
      onStderr() {},
    });
  } catch (error) {
    failure = error;
  }
  const metrics = collector.finish();
  const failures = collector.failureDiagnostics();
  const testCount = measuredMetric(metrics, "testCount");
  const passedCount = measuredMetric(metrics, "passedCount");
  const failedCount = measuredMetric(metrics, "failedCount");
  const skippedCount = measuredMetric(metrics, "skippedCount");
  if (failure) {
    process.stderr.write(`${JSON.stringify({
      schemaVersion: "licoup.flutter-test-diagnostics.v1",
      status: "failed",
      testCount,
      passedCount,
      failedCount,
      skippedCount,
      failures,
    })}\n`);
    throw failure;
  }
  process.stdout.write(`[client-toolchain-runner] Flutter tests passed: ${testCount ?? "unknown"} ` +
    `executed, ${skippedCount ?? "unknown"} skipped.\n`);
}

export async function runPreparedCommand(prepared, cwd) {
  try {
    if (prepared.captureFlutterTestOutput === true) {
      await runFlutterTestWithSafeDiagnostics(prepared, cwd);
    } else {
      await run(prepared.command, prepared.args, { cwd, env: prepared.env });
    }
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
