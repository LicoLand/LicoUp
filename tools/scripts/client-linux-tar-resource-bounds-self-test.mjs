#!/usr/bin/env node

import { validateLinuxTarListings } from "./lib/linux-tar-resource-bounds.mjs";

function rejects(action, label) {
  let rejected = false;
  try {
    action();
  } catch {
    rejected = true;
  }
  if (!rejected) throw new Error(label);
}

const listing = "bundle/\nbundle/client\n";
const verbose = [
  "drwxr-xr-x 0/0 0 2026-01-01 00:00:00 +0000 bundle/",
  "-rwxr-xr-x 0/0 1024 2026-01-01 00:00:00 +0000 bundle/client",
].join("\n");
const valid = validateLinuxTarListings(listing, verbose, {
  maxEntries: 2,
  maxSingleEntryBytes: 1024,
  maxExpandedBytes: 1024,
});
if (valid.entries.length !== 2 || valid.expandedBytes !== 1024) {
  throw new Error("valid Linux tar resource fixture failed");
}
rejects(() => validateLinuxTarListings(listing, verbose, { maxEntries: 1 }),
  "Linux tar entry-count bound was not enforced");
rejects(() => validateLinuxTarListings(listing, verbose, {
  maxSingleEntryBytes: 512,
}), "Linux tar single-entry bound was not enforced");
rejects(() => validateLinuxTarListings("bundle/\n../escape\n", verbose),
  "Linux tar traversal was accepted");
rejects(() => validateLinuxTarListings(
  listing,
  verbose.replace("-rwxr-xr-x", "lrwxr-xr-x"),
), "Linux tar symbolic link was accepted");

console.log(JSON.stringify({
  ok: true,
  caseCount: 5,
  unboundedExtractionAccepted: false,
  privatePathsIncluded: false,
}));
