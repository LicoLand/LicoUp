import { existsSync } from "node:fs";
import { matrix } from "./constants.mjs";
import { imageUrlFor, selectedDistros } from "./distro/select.mjs";
import { pathsFor } from "./paths.mjs";
import { runningPid } from "./vm/lifecycle.mjs";

export function printList(options) {
  const records = matrix.distros.map((distro) => {
    const vmPaths = pathsFor(distro);
    return {
      id: distro.id,
      label: distro.label,
      packageManager: distro.packageManager,
      imageConfigured: Boolean(imageUrlFor(distro)),
      manualImageRequired: Boolean(distro.manualImageRequired),
      prepared: existsSync(vmPaths.disk),
      running: Boolean(runningPid(distro)),
      note: distro.note || undefined,
    };
  });
  console.log(
    JSON.stringify(
      {
        ok: true,
        architecture: matrix.architecture,
        cacheRoot: "<client-cli-vm-cache-root>",
        distros: records,
        selected: selectedDistros(options).map((distro) => distro.id),
      },
      null,
      2,
    ),
  );
}
