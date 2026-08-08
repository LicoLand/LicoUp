import { SHA256 } from "../constants.mjs";
import { text } from "../util.mjs";

export function stableProducerSnapshotMatched(before, after) {
  return before?.digest === after?.digest &&
    before?.device === after?.device &&
    before?.inode === after?.inode;
}

export function digestBindingStable(expectedDigest, actualDigest) {
  return SHA256.test(text(expectedDigest)) && expectedDigest === actualDigest;
}
