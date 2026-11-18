import path from "node:path";
import process from "node:process";

import { packageFailure } from "../cli-policy.mjs";
import {
  MacosInstallError,
  installMacosApplication,
} from "../../../../../tools/scripts/lib/macos-app-lifecycle.mjs";

export function installRunnableClient(runnable, options) {
  if (!options.install) return null;
  if (options.platform !== "macos") packageFailure("install_platform_unsupported");
  try {
    return installMacosApplication({
      sourceApp: runnable.appPath,
      installDir: path.resolve(options.installDir || process.env.LICO_CLIENT_INSTALL_DIR || "/Applications"),
      manifestRoot: path.join(runnable.root, "package-metadata", "licoup"),
    }).installedAppPath;
  } catch (error) {
    packageFailure(error instanceof MacosInstallError ? error.code : "macos_install_failed", {
      stage: error instanceof MacosInstallError ? error.stage : "macos-install-replace-destination",
    });
  }
}
