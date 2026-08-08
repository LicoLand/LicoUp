import {
  createPublicKey,
  verify,
} from "node:crypto";
import { sha256Buffer } from "../../lib/client-release-artifact-digest.mjs";
import { SHA256 } from "../constants.mjs";
import { text } from "../util.mjs";

export function decodeCanonicalBase64(value) {
  const encoded = text(value);
  if (!encoded || encoded.length > 16 * 1024 ||
    !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/u.test(encoded)) {
    return Buffer.alloc(0);
  }
  const bytes = Buffer.from(encoded, "base64");
  return bytes.length > 0 && bytes.toString("base64") === encoded
    ? bytes
    : Buffer.alloc(0);
}

export function verifyLinuxArchiveDigestSignature(distribution, signatureBytes, artifactDigest) {
  try {
    if (!SHA256.test(text(artifactDigest)) || signatureBytes.length !== 64) return false;
    const publicKeyDer = decodeCanonicalBase64(
      distribution.signature?.publicKeySpkiBase64,
    );
    if (!publicKeyDer.length) return false;
    const publicKey = createPublicKey({ key: publicKeyDer, type: "spki", format: "der" });
    if (publicKey.asymmetricKeyType !== "ed25519" ||
      distribution.signature?.publicKeyFingerprint !== sha256Buffer(publicKeyDer)) {
      return false;
    }
    return verify(
      null,
      Buffer.from(artifactDigest.slice("sha256:".length), "hex"),
      publicKey,
      signatureBytes,
    );
  } catch {
    return false;
  }
}
