import { sha256File, stableHashFileSnapshot } from "../client-release-artifact-digest.mjs";
import {
  ANDROID_APK_RESOURCE_LIMITS,
  MAX_ANDROID_TOOL_BYTES,
  signerIdentityDigestByFacts,
} from "./limits.mjs";
import { requireValue } from "./require.mjs";
import { resolveAndroidToolchain, run } from "./sdk.mjs";
import { inspectAndroidApkZipFacts } from "./zip-facts.mjs";

export function inspectAndroidApkFacts(
  repoRoot,
  apkPath,
  { requireApprovedToolchain = false } = {},
) {
  const digestBefore = sha256File(apkPath, {
    maxBytes: ANDROID_APK_RESOURCE_LIMITS.maxApkBytes,
  });
  const nativeSecureMeshLibrary = inspectAndroidApkZipFacts(apkPath);
  const toolchain = resolveAndroidToolchain(repoRoot, requireApprovedToolchain);
  const { aapt2, apksigner, zipalign } = toolchain;
  const toolPaths = [
    aapt2,
    apksigner,
    toolchain.apksignerJar,
    zipalign,
    toolchain.java,
  ];
  const toolsBefore = toolPaths.map((tool) => stableHashFileSnapshot(tool, {
    maxBytes: MAX_ANDROID_TOOL_BYTES,
  }));
  const badging = run(aapt2, ["dump", "badging", apkPath], repoRoot, toolchain.env);
  const signature = run(
    apksigner,
    ["verify", "--verbose", "--print-certs", "--Werr", apkPath],
    repoRoot,
    toolchain.env,
  );
  run(zipalign, ["-c", "-P", "16", "-v", "4", apkPath], repoRoot, toolchain.env);
  const toolsAfter = toolPaths.map((tool) => stableHashFileSnapshot(tool, {
    maxBytes: MAX_ANDROID_TOOL_BYTES,
  }));
  requireValue(toolsBefore.every((before, index) =>
    before.digest === toolsAfter[index].digest &&
      before.device === toolsAfter[index].device &&
      before.inode === toolsAfter[index].inode),
  "Android APK verification toolchain changed during fact extraction");
  const digestAfter = sha256File(apkPath, {
    maxBytes: ANDROID_APK_RESOURCE_LIMITS.maxApkBytes,
  });
  requireValue(digestBefore === digestAfter, "Android APK changed during fact extraction");
  const packageMatch = badging.match(
    /package:\s+name='([^']+)'\s+versionCode='([^']+)'\s+versionName='([^']*)'/u,
  );
  requireValue(packageMatch, "Android APK package facts are unavailable");
  const signerCount = Number(signature.match(/Number of signers:\s*(\d+)/iu)?.[1] || 0);
  requireValue(signerCount === 1,
    "Android APK must contain exactly one signer");
  const signerDigests = [...signature.matchAll(
    /(?:Signer #\d+|V[1-4] Signer):\s*certificate SHA-256 digest:\s*([0-9a-f]{64})/giu,
  )].map((match) => match[1].toLowerCase());
  const uniqueSignerDigests = [...new Set(signerDigests)];
  requireValue(uniqueSignerDigests.length === 1,
    "Android APK must contain exactly one signing identity");
  const signerDigest = uniqueSignerDigests[0];
  requireValue(/^[a-f0-9]{64}$/u.test(signerDigest),
    "Android APK signer certificate digest is unavailable");
  const nativeCodeLine = badging.split(/\r?\n/u)
    .find((line) => line.startsWith("native-code:")) || "";
  const abis = [...nativeCodeLine.matchAll(/'([^']+)'/gu)]
    .map((match) => match[1])
    .sort();
  requireValue(abis.length > 0, "Android APK native ABI facts are unavailable");
  const launchableActivity = badging.match(
    /launchable-activity:\s+name='([^']+)'/u,
  )?.[1] || "";
  requireValue(launchableActivity, "Android APK launchable activity is unavailable");
  const versionCode = String(packageMatch[2]);
  requireValue(/^\d+$/u.test(versionCode) && BigInt(versionCode) > 0n,
    "Android APK versionCode is invalid");
  const signatureSchemes = [...signature.matchAll(
    /Verified using v([1-4]) scheme[^:]*:\s*(true|false)/giu,
  )].filter((match) => match[2].toLowerCase() === "true")
    .map((match) => `v${match[1]}`)
    .sort();
  requireValue(signatureSchemes.some((scheme) => ["v2", "v3", "v4"].includes(scheme)),
    "Android APK lacks a modern signature scheme");
  const facts = Object.freeze({
    artifactDigest: digestBefore,
    packageName: packageMatch[1],
    versionCode,
    versionName: packageMatch[3],
    debuggable: /(?:^|\n)application-debuggable(?:\r?\n|$)/u.test(badging),
    abis: Object.freeze(abis),
    launchableActivity,
    signerCount,
    signatureSchemes: Object.freeze(signatureSchemes),
    zipAligned: true,
    nativeSecureMeshLibrary,
  });
  signerIdentityDigestByFacts.set(facts, `sha256:${signerDigest}`);
  return facts;
}
