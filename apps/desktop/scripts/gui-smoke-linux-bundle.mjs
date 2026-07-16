import { existsSync, mkdirSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawn, spawnSync } from "node:child_process";
import process from "node:process";
import { fileURLToPath } from "node:url";

const workspaceRoot = path.resolve(fileURLToPath(new URL("../../..", import.meta.url)));
const bundleRoot = path.join(workspaceRoot, "build", "apps", "desktop", "bundles", "linux");

function findLinuxBundle() {
  const candidates = [];
  for (const mode of existsSync(bundleRoot) ? readdirSync(bundleRoot) : []) {
    const bundleDir = path.join(bundleRoot, mode, "bundle");
    if (existsSync(path.join(bundleDir, "flutter_client"))) {
      candidates.push(bundleDir);
    }
  }
  if (candidates.length === 0) {
    throw new Error("No Linux bundle found. Run npm run client:build:linux first.");
  }
  candidates.sort((left, right) => statSync(right).mtimeMs - statSync(left).mtimeMs);
  return candidates[0];
}

function requireTool(name) {
  const result = spawnSync("bash", ["-lc", `command -v ${name}`], {
    encoding: "utf8",
  });
  if (result.status !== 0) {
    throw new Error(`Required GUI test tool is missing: ${name}`);
  }
  return result.stdout.trim();
}

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    encoding: "utf8",
    ...options,
  });
  if (result.status !== 0) {
    throw new Error(
      `${command} ${args.join(" ")} failed\nstdout:\n${result.stdout}\nstderr:\n${result.stderr}`,
    );
  }
  return result.stdout;
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function waitFor(predicate, timeoutMs, label) {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    const value = predicate();
    if (value) {
      return value;
    }
    await sleep(150);
  }
  throw new Error(`Timed out waiting for ${label}`);
}

function captureWindow(pathname, env, windowId) {
  const result = spawnSync("import", ["-window", windowId, pathname], {
    env,
    encoding: "utf8",
  });
  if (result.status === 0) {
    return;
  }
  run("scrot", [pathname], { env });
}

function screenshot(pathname, env, windowId) {
  captureWindow(pathname, env, windowId);
  const size = statSync(pathname).size;
  if (size < 1_000) {
    throw new Error(`Screenshot is unexpectedly small: ${pathname} (${size} bytes)`);
  }
  const colorsRaw = run("identify", ["-format", "%k", pathname], { env }).trim();
  const colors = Number.parseInt(colorsRaw, 10);
  if (!Number.isFinite(colors) || colors < 8) {
    throw new Error(`Screenshot appears blank: ${pathname} (${colorsRaw} colors)`);
  }
  return { path: pathname, byteSize: size, colors };
}

async function waitForScreenshot(pathname, env, windowId, timeoutMs) {
  const start = Date.now();
  let lastError;
  while (Date.now() - start < timeoutMs) {
    try {
      return screenshot(pathname, env, windowId);
    } catch (error) {
      lastError = error;
      await sleep(500);
    }
  }
  throw lastError || new Error(`Timed out waiting for screenshot: ${pathname}`);
}

async function main() {
  if (process.platform !== "linux") {
    throw new Error("Linux GUI smoke tests must run inside Linux.");
  }

  requireTool("Xvfb");
  requireTool("xdotool");
  requireTool("scrot");
  requireTool("identify");

  const bundleDir = findLinuxBundle();
  const flutterBinary = path.join(bundleDir, "flutter_client");
  const cli = path.join(bundleDir, "lico-client");
  const packagingManifest = path.join(
    bundleDir,
    "package-metadata",
    "lico-client",
    "packaging-modules.json"
  );
  for (const file of [flutterBinary, cli]) {
    if (!existsSync(file)) {
      throw new Error(`Bundle binary is missing: ${file}`);
    }
  }
  if (!existsSync(packagingManifest)) {
    throw new Error(`Packaging manifest is missing: ${packagingManifest}`);
  }
  const manifest = JSON.parse(readFileSync(packagingManifest, "utf8"));
  const enabledModuleIds = new Set(manifest.modules?.map((item) => item.id) || []);
  for (const moduleId of [
    "desktop-app",
    "native-sidecar",
    "portable-data",
    "target-adapters",
    "local-task-queue",
    "protocol-adapters",
  ]) {
    if (!enabledModuleIds.has(moduleId)) {
      throw new Error(`Packaging manifest does not include required module: ${moduleId}`);
    }
  }
  const artifactDir = path.resolve(
    process.env.LICO_GUI_ARTIFACT_DIR ||
      path.join(workspaceRoot, "build", "artifacts", "desktop-app", "linux-gui-smoke"),
  );
  mkdirSync(artifactDir, { recursive: true });

  const dataDir = path.join(os.tmpdir(), `lico-linux-gui-${process.pid}-${Date.now()}`);
  mkdirSync(dataDir, { recursive: true });

  const display = `:${100 + (process.pid % 400)}`;
  const env = {
    ...process.env,
    DISPLAY: display,
    GDK_BACKEND: "x11",
    GDK_GL: "software",
    LIBGL_ALWAYS_SOFTWARE: "1",
    NO_AT_BRIDGE: "1",
    LICOARC_PORTABLE_DIR: dataDir,
  };
  const xvfb = spawn(
    "Xvfb",
    [display, "-screen", "0", "1440x900x24", "-ac", "+extension", "GLX", "+render", "-noreset", "-nolisten", "tcp"],
    { stdio: "ignore" },
  );
  const stdout = [];
  const stderr = [];
  let app;

  try {
    await sleep(500);
    if (xvfb.exitCode != null) {
      throw new Error(`Xvfb exited early with code ${xvfb.exitCode}`);
    }

    app = spawn(flutterBinary, ["--enable-software-rendering"], {
      cwd: bundleDir,
      env,
      stdio: ["ignore", "pipe", "pipe"],
    });
    app.stdout.on("data", (chunk) => stdout.push(chunk.toString()));
    app.stderr.on("data", (chunk) => stderr.push(chunk.toString()));

    const windowId = await waitFor(() => {
      if (app.exitCode != null) {
        throw new Error(
          `Flutter app exited early with code ${app.exitCode}\nstdout:\n${stdout.join("")}\nstderr:\n${stderr.join("")}`,
        );
      }
      for (const args of [
        ["search", "--onlyvisible", "--name", "Lico Arc|Arc|lico|flutter_client|Flutter"],
        ["search", "--onlyvisible", "--name", ".*"],
      ]) {
        const result = spawnSync("xdotool", args, {
          env,
          encoding: "utf8",
        });
        const windowId = result.status === 0
          ? result.stdout.trim().split(/\s+/).find(Boolean)
          : "";
        if (windowId) {
          return windowId;
        }
      }
      return "";
    }, 20_000, "visible Flutter window");

    spawnSync("xdotool", ["windowmap", windowId], { env, stdio: "ignore" });
    spawnSync("xdotool", ["windowmove", windowId, "40", "40"], { env, stdio: "ignore" });
    spawnSync("xdotool", ["windowsize", windowId, "1280", "800"], { env, stdio: "ignore" });

    await sleep(1500);
    const initial = await waitForScreenshot(
      path.join(artifactDir, "lico-linux-initial.png"),
      env,
      windowId,
      30_000,
    );
    run("xdotool", ["mousemove", "360", "280", "click", "1", "key", "Tab", "key", "Tab"], {
      env,
    });
    await sleep(750);
    const afterInteraction = await waitForScreenshot(
      path.join(artifactDir, "lico-linux-after-interaction.png"),
      env,
      windowId,
      10_000,
    );

    console.log(JSON.stringify({
      ok: true,
      bundleDir,
      artifactDir,
      dataDir,
      windowId,
      screenshots: [initial, afterInteraction],
      checks: [
        "Flutter Linux bundle launches under Ubuntu X11",
        "visible window is discoverable",
        "screenshots are nonblank",
        "basic pointer and keyboard interaction does not crash",
        "current client sidecar is bundled",
      ],
    }, null, 2));
  } finally {
    writeFileSync(path.join(artifactDir, "lico-linux-app-stdout.log"), stdout.join(""));
    writeFileSync(path.join(artifactDir, "lico-linux-app-stderr.log"), stderr.join(""));
    if (app && app.exitCode == null) {
      app.kill("SIGTERM");
      await sleep(500);
      if (app.exitCode == null) {
        app.kill("SIGKILL");
      }
    }
    if (xvfb.exitCode == null) {
      xvfb.kill("SIGTERM");
    }
    rmSync(dataDir, { recursive: true, force: true });
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
