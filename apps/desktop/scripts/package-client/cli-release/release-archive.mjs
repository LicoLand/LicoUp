import { gunzipSync } from "node:zlib";

import { packageFailure } from "../cli-policy.mjs";

const BLOCK = 512;

/**
 * Reads the named regular files from a gzip-compressed tar archive.
 *
 * Only the requested root-level members are returned; every other entry is
 * left unread and nothing is written to disk, so the archive cannot place a
 * file outside the staging directory. A requested member that is missing,
 * repeated, or not a regular file fails closed.
 */
export function readArchiveMembers(archiveBytes, names) {
  let tar;
  try {
    tar = gunzipSync(archiveBytes);
  } catch {
    packageFailure("cli_release_archive_invalid");
  }
  const wanted = new Set(names);
  const members = new Map();
  let pendingPath = null;
  for (let offset = 0; offset + BLOCK <= tar.length;) {
    const header = tar.subarray(offset, offset + BLOCK);
    if (header.every((byte) => byte === 0)) break;
    const size = octal(header.subarray(124, 136));
    const type = String.fromCharCode(header[156] || 48);
    const bodyStart = offset + BLOCK;
    const bodyEnd = bodyStart + size;
    if (bodyEnd > tar.length) packageFailure("cli_release_archive_invalid");
    const body = tar.subarray(bodyStart, bodyEnd);
    offset = bodyStart + Math.ceil(size / BLOCK) * BLOCK;
    if (type === "x") {
      pendingPath = paxPath(body);
      continue;
    }
    if (type === "g") continue;
    const name = normalizedName(pendingPath ?? headerName(header));
    pendingPath = null;
    if (!wanted.has(name)) continue;
    if ((type !== "0" && type !== "\0") || members.has(name)) {
      packageFailure("cli_release_archive_invalid");
    }
    members.set(name, Buffer.from(body));
  }
  for (const name of wanted) {
    if (!members.has(name)) packageFailure("cli_release_archive_member_missing");
  }
  return members;
}

function headerName(header) {
  const name = text(header.subarray(0, 100));
  const prefix = text(header.subarray(345, 500));
  return prefix ? `${prefix}/${name}` : name;
}

function normalizedName(name) {
  return name.replace(/^(?:\.\/)+/u, "");
}

function paxPath(body) {
  for (const record of body.toString("utf8").split("\n")) {
    const match = /^\d+ path=(.*)$/u.exec(record);
    if (match) return match[1];
  }
  return null;
}

function text(bytes) {
  const end = bytes.indexOf(0);
  return bytes.subarray(0, end < 0 ? bytes.length : end).toString("utf8");
}

function octal(bytes) {
  const value = text(bytes).trim();
  if (!/^[0-7]*$/u.test(value)) packageFailure("cli_release_archive_invalid");
  return value ? Number.parseInt(value, 8) : 0;
}
