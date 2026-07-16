import { existsSync, rmSync } from "node:fs";
import process from "node:process";
import {
  createReleaseClosureChallenge,
  createReleaseInvocationNonce,
  requiredReleaseClosureChallenge,
  requiredReleaseClosureStartedAt,
  requiredReleaseInvocationNonce,
} from "../../lib/release-closure-challenge.mjs";
import { fetchArtifacts } from "../sync/artifacts.mjs";
import { syncRepoToVm } from "../sync/repo.mjs";
import { runSsh } from "../ssh/session.mjs";
import { prepareDistro } from "../vm/prepare.mjs";
import { shutdownDistro, startDistro, waitForSsh } from "../vm/lifecycle.mjs";
import {
  clearLinuxProductHostArtifacts,
  linuxProductArtifactPaths,
} from "./artifacts.mjs";
import { linuxProductBootstrapCommand } from "./bootstrap.mjs";
import { linuxProductCommand } from "./command.mjs";
import { writeLinuxProductIncomplete } from "./incomplete.mjs";
import {
  createLinuxProductSourceManifest,
  currentClientSourceDigest,
  syncLinuxProductSourceManifest,
  verifyLinuxProductSourceManifest,
} from "./source-manifest.mjs";
import { validateLinuxProductArtifacts } from "./validate.mjs";

export function verifyLinuxProductDistro(distro, options) {
  clearLinuxProductHostArtifacts(distro);
  const inheritedClosure = String(
    process.env.LICO_CLIENT_RELEASE_CLOSURE_CHALLENGE || "",
  ).trim();
  const releaseBinding = Object.freeze({
    challenge: inheritedClosure
      ? requiredReleaseClosureChallenge()
      : createReleaseClosureChallenge(),
    invocationNonce: inheritedClosure
      ? requiredReleaseInvocationNonce()
      : createReleaseInvocationNonce(),
    startedAt: inheritedClosure
      ? requiredReleaseClosureStartedAt().value
      : new Date().toISOString(),
  });
  const sourceBefore = currentClientSourceDigest();
  let sourceManifestDigest = "";
  prepareDistro(distro, options);
  startDistro(distro, options);
  waitForSsh(distro, options.bootTimeoutSeconds);
  try {
    console.log(`[client-cli-vm] Preparing Linux product toolchain for ${distro.id}.`);
    runSsh(distro, linuxProductBootstrapCommand(distro));
    if (currentClientSourceDigest() !== sourceBefore) {
      writeLinuxProductIncomplete(distro, "source_state_changed_before_sync");
      throw new Error(
        "Client source changed before Linux product sync; verification was not started.",
      );
    }
    sourceManifestDigest = createLinuxProductSourceManifest(distro, sourceBefore);
    if (currentClientSourceDigest() !== sourceBefore) {
      writeLinuxProductIncomplete(distro, "source_state_changed_during_manifest_creation");
      throw new Error("Client source changed while creating the Linux source manifest.");
    }
    console.log(`[client-cli-vm] Syncing current source for ${distro.id} Linux product proof.`);
    syncRepoToVm(distro);
    syncLinuxProductSourceManifest(distro);
    if (currentClientSourceDigest() !== sourceBefore) {
      writeLinuxProductIncomplete(distro, "source_state_changed_during_sync");
      throw new Error(
        "Client source changed during Linux product sync; verification was not started.",
      );
    }
    if (
      verifyLinuxProductSourceManifest(distro, sourceBefore).manifestDigest !==
      sourceManifestDigest
    ) {
      writeLinuxProductIncomplete(distro, "source_manifest_changed_during_sync");
      throw new Error("Client source manifest changed during Linux product sync.");
    }
    console.log(
      `[client-cli-vm] Building and verifying current Linux product on ${distro.id}.`,
    );
    runSsh(distro, linuxProductCommand(distro, sourceBefore, releaseBinding));
    if (currentClientSourceDigest() !== sourceBefore) {
      writeLinuxProductIncomplete(distro, "source_state_changed_during_verification");
      throw new Error(
        "Client source changed during Linux product verification; ready evidence was rejected.",
      );
    }
    if (
      verifyLinuxProductSourceManifest(distro, sourceBefore).manifestDigest !==
      sourceManifestDigest
    ) {
      writeLinuxProductIncomplete(distro, "source_manifest_changed_during_verification");
      throw new Error("Client source manifest changed during Linux product verification.");
    }
    fetchArtifacts(distro, "lico-product-artifacts");
    if (currentClientSourceDigest() !== sourceBefore) {
      writeLinuxProductIncomplete(distro, "source_state_changed_during_artifact_binding");
      throw new Error(
        "Client source changed while binding Linux product artifacts; ready evidence was rejected.",
      );
    }
    if (
      verifyLinuxProductSourceManifest(distro, sourceBefore).manifestDigest !==
      sourceManifestDigest
    ) {
      writeLinuxProductIncomplete(distro, "source_manifest_changed_during_artifact_binding");
      throw new Error(
        "Client source manifest changed while binding Linux product artifacts.",
      );
    }
    validateLinuxProductArtifacts(distro, sourceBefore, releaseBinding);
    rmSync(linuxProductArtifactPaths(distro).incomplete, { force: true });
    console.log(
      JSON.stringify(
        {
          ok: true,
          target: "ubuntu-linux-arm64",
          currentSourceArchive: true,
          vmInstallReceiptReady: true,
          threeNodeMatrixReady: true,
          archivedReleaseCliProofReady: true,
          sourceBindingStale: false,
          runtimeDataIncluded: false,
        },
        null,
        2,
      ),
    );
  } catch (error) {
    if (!existsSync(linuxProductArtifactPaths(distro).incomplete)) {
      writeLinuxProductIncomplete(distro, "linux_product_verification_failed");
    }
    throw error;
  } finally {
    if (!options.keepRunning) shutdownDistro(distro);
  }
}
