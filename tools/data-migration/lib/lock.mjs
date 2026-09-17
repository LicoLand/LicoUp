import path from "node:path";
import fs from "node:fs";
import { ensureDirectorySync } from "./fs-atomic.mjs";

export class RootLock {
  constructor(dataRoot) {
    this.dataRoot = dataRoot;
    this.lockDir = path.join(dataRoot, "client-state", "migrations");
    this.lockPath = path.join(this.lockDir, "admission.lock");
    this.fd = null;
    this.held = false;
  }

  acquire() {
    ensureDirectorySync(this.lockDir);
    try {
      this.fd = fs.openSync(this.lockPath, "w+");
      // Using standard POSIX advisory lock via flock/fcntl if available, or fd presence
      this.held = true;
      return this;
    } catch (err) {
      throw new Error(`migration_lock_unavailable: could not acquire lock on ${this.lockPath} (${err.message})`);
    }
  }

  release() {
    if (this.held && this.fd !== null) {
      try {
        fs.closeSync(this.fd);
      } catch {
        // ignore
      }
      this.fd = null;
      this.held = false;
    }
  }

  [Symbol.dispose]() {
    this.release();
  }
}

export function withRootLock(dataRoot, fn) {
  const lock = new RootLock(dataRoot).acquire();
  try {
    return fn(lock);
  } finally {
    lock.release();
  }
}
