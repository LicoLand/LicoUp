import { requireFact } from "../../../architecture-graph/lib/canonical.mjs";
import { deliveryTasksForPackage } from "../../catalog/lib/lock.mjs";

/**
 * Read-only profile previews and removal-impact previews.
 *
 * Package dependency closure and removal refusal are defined by the typed graph.
 * Synthetic fixtures verify the decisions independently of a local execution plan.
 *
 * These previews describe declarations. They do not inspect a real installation,
 * download, execute or delete anything, and they never mutate the graph, the
 * development ledger or a task status. Only `task.depends_on` schedules work, so
 * nothing in this file can advance or block a task.
 */

export const PROFILE_NOTE = "Target fixed-catalog closure only. Not an installed inventory, measured artifact size, or permission to install.";
export const REMOVAL_NOTE = "No cascade, no deletion. Real runtime must inspect active/unknown invocations, platform handles, artifact refcounts and retained user data.";

function requireProfile(graph, profileId) {
  requireFact(graph.distribution !== null, "a distribution graph is required");
  const profile = graph.profiles.get(profileId);
  requireFact(profile !== undefined, `unknown profile: ${profileId}`);
  return profile;
}

/** The declared closure of one profile. Computed from the supplied package graph. */
export function profilePreview(graph, profileId) {
  const profile = requireProfile(graph, profileId);
  const closure = [...graph.packageClosure(profile.selected_packages)].sort();
  return {
    proposal_only: true,
    profile: profileId,
    selected_packages: [...profile.selected_packages],
    dependency_closure: closure,
    not_selected: [...graph.packages.keys()].filter((packageId) => !closure.includes(packageId)).sort(),
    measured_bytes: null,
    note: PROFILE_NOTE,
  };
}

/**
 * The declared impact of removing one package from one profile.
 *
 * `pinned` simulates active generations that still reference a package; those
 * are reported as retainers rather than silently removed.
 */
export function removalPreview(graph, { profileId, packageId, pinned = [] }) {
  requireProfile(graph, profileId);
  const preview = profilePreview(graph, profileId);
  const inventory = new Set(preview.dependency_closure);
  requireFact(inventory.has(packageId), `package not in selected profile: ${packageId}`);
  requireFact(packageId !== graph.distribution.core_package, "core is not an uninstallable feature");
  const pins = [...new Set(pinned)].sort();
  const unknownPins = pins.filter((pin) => !inventory.has(pin));
  requireFact(unknownPins.length === 0, `pin not in selected profile: ${unknownPins.join(", ")}`);
  const dependents = [...inventory]
    .filter((candidate) => candidate !== packageId && graph.packageClosure([candidate]).has(packageId))
    .sort();
  const retainers = pins.filter((pin) => graph.packageClosure([pin]).has(packageId));
  return {
    proposal_only: true,
    profile: profileId,
    package: packageId,
    blocking_dependents: dependents,
    active_pin_retainers: retainers,
    can_remove_bytes_in_this_model: dependents.length === 0 && retainers.length === 0,
    note: REMOVAL_NOTE,
  };
}

/**
 * The same profile, with installation, runtime activation and delivery
 * responsibility kept apart. Mixing them is how an install dependency starts
 * reading as a development wait.
 */
export function profileDeliveryView(graph, profileId) {
  const profile = requireProfile(graph, profileId);
  const preview = profilePreview(graph, profileId);
  const activation = {};
  for (const packageId of preview.dependency_closure) {
    activation[packageId] = graph.packages.get(packageId).activation;
  }
  const taskIds = [...new Set(preview.dependency_closure.flatMap((packageId) => deliveryTasksForPackage(graph, packageId)))].sort();
  return {
    kind: "licoup-distribution-profile.v1",
    ...preview,
    runtime_activation: activation,
    delivery_tasks: taskIds.map((taskId) => ({
      id: taskId,
      fingerprint: graph.taskFingerprint(taskId),
      packages: [...graph.tasks.get(taskId).packages].sort(),
    })),
    separated_relations: {
      install: "requires_package transitive closure only",
      runtime: "activation mode per installed package; no process is started here",
      delivery: "tasks responsible for the packages; never a development prerequisite",
    },
  };
}
