import { createHash } from "node:crypto";
import { readdirSync, readFileSync } from "node:fs";
import path from "node:path";

/** Repository-relative root of the conversation protocol schema tree. */
export const CONVERSATION_PROTOCOL_SCHEMA_ROOT = "schemas/conversation_protocol";

/**
 * The C1 conversation protocol digest of one repository checkout.
 *
 * Every regular file under `schemas/conversation_protocol/` contributes one
 * `<repo-relative path>\0<sha256 hex of the file>\n` line; the lines are ordered
 * by the byte order of their `/`-separated paths and the concatenation is hashed
 * with SHA-256. LicoUp-CLI implements the same function for `contract.json`, so
 * equal digests mean both sides were generated from the same schema bytes.
 */
export function conversationProtocolDigest(repositoryRoot) {
  const files = schemaFiles(repositoryRoot, CONVERSATION_PROTOCOL_SCHEMA_ROOT);
  if (files.length === 0) throw new Error("conversation_protocol_schema_missing");
  files.sort((left, right) => Buffer.compare(Buffer.from(left), Buffer.from(right)));
  const digest = createHash("sha256");
  for (const relative of files) {
    const fileDigest = createHash("sha256")
      .update(readFileSync(path.join(repositoryRoot, ...relative.split("/"))))
      .digest("hex");
    digest.update(`${relative}\0${fileDigest}\n`);
  }
  return digest.digest("hex");
}

/** The stdio protocol identity the Desktop's schema copy declares. */
export function conversationProtocolVersion(repositoryRoot) {
  const schema = JSON.parse(readFileSync(
    path.join(
      repositoryRoot,
      CONVERSATION_PROTOCOL_SCHEMA_ROOT,
      "conversation_protocol.schema.json",
    ),
    "utf8",
  ));
  const version = String(schema.protocolVersion || "").trim();
  if (!version) throw new Error("conversation_protocol_version_missing");
  return version;
}

function schemaFiles(repositoryRoot, relativeDirectory) {
  const files = [];
  const entries = readdirSync(
    path.join(repositoryRoot, ...relativeDirectory.split("/")),
    { withFileTypes: true },
  );
  for (const entry of entries) {
    const relative = `${relativeDirectory}/${entry.name}`;
    if (entry.isDirectory()) {
      files.push(...schemaFiles(repositoryRoot, relative));
    } else if (entry.isFile()) {
      files.push(relative);
    }
  }
  return files;
}
