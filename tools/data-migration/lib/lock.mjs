import path from "node:path";
import fs from "node:fs";
import { ensureDirectorySync } from "./fs-atomic.mjs";

// Exclusive execution lock for the independent tool. The native client owns
// `admission.lock` (flock-based, managed by the Rust admission path); this
// tool must neither truncate nor fake-lock that file. Cross-process lock
// ordering with the native host belongs to the T08.3 root-access protocol;
// this lock guarantees mutual exclusion between data-migration tool runs.
export class RootLock {
  constructor(dataRoot) {
    this.dataRoot = dataRoot;
    this.lockDir = path.join(dataRoot, "client-state", "migrations");
    this.lockPath = path.join(this.lockDir, "data-migration.lock");
    this.acquired = false;
  }

  acquire() {
    ensureDirectorySync(this.lockDir);
    const payload = JSON.stringify({
      pid: process.pid,
      acquiredAt: new Date().toISOString(),
    }) + "\n";
    for (let attempt = 0; attempt < 2; attempt++) {
      try {
        // Atomic create-with-content: no window where the lock exists but
        // carries no owner identity.
        fs.writeFileSync(this.lockPath, payload, { flag: "wx", mode: 0o600 });
        this.acquired = true;
        return this;
      } catch (err) {
        if (err.code !== "EEXIST") {
          throw new Error(`migration_lock_unavailable: could not acquire lock on ${this.lockPath} (${err.message})`);
        }
        if (attempt === 0 && this.reclaimIfStale()) {
          continue;
        }
        throw new Error(`migration_lock_unavailable: another data-migration process holds ${this.lockPath}`);
      }
    }
    return this;
  }

  reclaimIfStale() {
    let owner = null;
    try {
      owner = JSON.parse(fs.readFileSync(this.lockPath, "utf8"));
    } catch {
      owner = null;
    }
    const pid = owner && Number.isInteger(owner.pid) ? owner.pid : null;
    if (pid !== null) {
      try {
        process.kill(pid, 0);
        return false; // owner process is alive
      } catch (err) {
        if (err.code === "EPERM") {
          return false; // alive but owned by another user
        }
      }
    }
    try {
      fs.unlinkSync(this.lockPath);
      return true;
    } catch {
      return false;
    }
  }

  release() {
    if (this.acquired) {
      try {
        fs.unlinkSync(this.lockPath);
      } catch {
        // ignore
      }
      this.acquired = false;
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
