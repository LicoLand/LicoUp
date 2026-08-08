export const ANDROID_APK_RESOURCE_LIMITS = Object.freeze({
  maxApkBytes: 1024 * 1024 * 1024,
  maxEntries: 50_000,
  maxCentralDirectoryBytes: 64 * 1024 * 1024,
  maxEntryMetadataBytes: 256 * 1024,
  maxPathBytes: 4 * 1024,
  maxEntryUncompressedBytes: 1024 * 1024 * 1024,
  maxTotalUncompressedBytes: 4 * 1024 * 1024 * 1024,
  maxNativeLibraryBytes: 256 * 1024 * 1024,
});
export const MAX_APK_SIGNING_BLOCK_BYTES = 64 * 1024 * 1024;
export const MAX_ANDROID_TOOL_BYTES = 1024 * 1024 * 1024;
export const signerIdentityDigestByFacts = new WeakMap();
