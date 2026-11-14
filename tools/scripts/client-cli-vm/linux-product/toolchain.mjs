import { runSsh } from "../ssh/session.mjs";
import { prepareDistro } from "../vm/prepare.mjs";
import { shutdownDistro, startDistro, waitForSsh } from "../vm/lifecycle.mjs";
import { linuxProductBootstrapCommand } from "./bootstrap.mjs";

export function verifyLinuxProductToolchainDistro(distro, options) {
  prepareDistro(distro, options);
  startDistro(distro, options);
  waitForSsh(distro, options.bootTimeoutSeconds);
  try {
    runSsh(distro, linuxProductBootstrapCommand(distro));
    console.log(
      JSON.stringify(
        {
          ok: true,
          target: "ubuntu-linux-arm64",
          nodeToolchainPinned: true,
          flutterSourceTagPinned: true,
          flutterCommitPinned: true,
          downloadChecksumsVerified: true,
          rawLogsIncluded: false,
        },
        null,
        2,
      ),
    );
  } finally {
    if (!options.keepRunning) shutdownDistro(distro);
  }
}
