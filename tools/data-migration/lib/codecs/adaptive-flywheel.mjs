import path from "node:path";
import fs from "node:fs";
import { DatabaseSync } from "node:sqlite";
import {
  writeJsonAtomicSync,
  readJsonSync,
  ensureDirectorySync,
  isRegularFileSync,
  removeFileSync,
} from "../fs-atomic.mjs";
import { savePreservation, loadPreservation, clearPreservation } from "../preservation.mjs";

const DOMAIN_ID = "adaptive-flywheel";

export function getDatabasePath(dataRoot) {
  return path.join(dataRoot, "client-state", "adaptive-flywheel", "strategies.sqlite3");
}

export function getLegacyTomlPath(dataRoot) {
  return path.join(dataRoot, "client-state", "adaptive-flywheel.toml");
}

export function readStrategyMetaVersion(dbPath) {
  if (!isRegularFileSync(dbPath)) {
    return null;
  }
  let db;
  try {
    db = new DatabaseSync(dbPath, { readOnly: true });
    const row = db.prepare("SELECT value FROM strategy_meta WHERE key = ?").get("version");
    return row ? String(row.value) : null;
  } catch {
    return null;
  } finally {
    if (db) {
      try { db.close(); } catch {}
    }
  }
}

export function probe(dataRoot) {
  const dbPath = getDatabasePath(dataRoot);
  const tomlPath = getLegacyTomlPath(dataRoot);

  if (isRegularFileSync(dbPath)) {
    const ver = readStrategyMetaVersion(dbPath);
    if (ver === "3") {
      return { version: 2, present: true, strategyMetaVersion: "3" };
    }
    if (ver === "2") {
      return { version: 1, present: true, strategyMetaVersion: "2" };
    }
    if (ver !== null && Number(ver) < 2) {
      return { version: 0, present: true, strategyMetaVersion: ver };
    }
    return { version: 0, present: true };
  }

  if (isRegularFileSync(tomlPath)) {
    return { version: 0, present: true };
  }

  return { version: 0, present: false };
}

export function forward(dataRoot, fromVer, toVer) {
  const dbPath = getDatabasePath(dataRoot);
  ensureDirectorySync(path.dirname(dbPath));

  if (fromVer === 0 && toVer === 1) {
    let db;
    try {
      db = new DatabaseSync(dbPath);
      db.exec(`
        CREATE TABLE IF NOT EXISTS strategy_meta (
          key TEXT PRIMARY KEY,
          value TEXT NOT NULL
        );
        INSERT INTO strategy_meta (key, value) VALUES ('version', '2')
        ON CONFLICT(key) DO UPDATE SET value='2';
        CREATE TABLE IF NOT EXISTS strategy_definitions (
          definition_id TEXT NOT NULL,
          revision_digest TEXT PRIMARY KEY,
          semantics_digest TEXT NOT NULL,
          name TEXT NOT NULL,
          version TEXT NOT NULL,
          workflow_json TEXT NOT NULL,
          asset_count INTEGER NOT NULL,
          imported_at INTEGER NOT NULL
        );
      `);
    } finally {
      if (db) {
        try { db.close(); } catch {}
      }
    }
    removeFileSync(getLegacyTomlPath(dataRoot));
    return { converted: true, details: "migrated adaptive flywheel to schema 2" };
  }

  if (fromVer === 1 && toVer === 2) {
    let db;
    try {
      db = new DatabaseSync(dbPath);
      db.exec(`
        UPDATE strategy_meta SET value='3' WHERE key='version';
      `);
      // Restore preserved routing definitions if any
      const preserved = loadPreservation(dataRoot, DOMAIN_ID);
      if (preserved && preserved.preservedData && preserved.preservedData.definitions) {
        const updateStmt = db.prepare("UPDATE strategy_definitions SET workflow_json = ? WHERE revision_digest = ?");
        for (const [rev, wf] of Object.entries(preserved.preservedData.definitions)) {
          updateStmt.run(wf, rev);
        }
        clearPreservation(dataRoot, DOMAIN_ID);
      }
    } finally {
      if (db) {
        try { db.close(); } catch {}
      }
    }
    return { converted: true, details: "migrated adaptive flywheel to schema 3 (workflow routing)" };
  }

  if (fromVer === 0 && toVer === 2) {
    forward(dataRoot, 0, 1);
    return forward(dataRoot, 1, 2);
  }

  throw new Error(`Unsupported forward migration edge for ${DOMAIN_ID}: ${fromVer} -> ${toVer}`);
}

export function reverse(dataRoot, fromVer, toVer) {
  const dbPath = getDatabasePath(dataRoot);

  if (fromVer === 2 && toVer === 1) {
    if (isRegularFileSync(dbPath)) {
      let db;
      try {
        db = new DatabaseSync(dbPath);
        // Save definitions with workflow routing to preservation
        const rows = db.prepare("SELECT revision_digest, workflow_json FROM strategy_definitions").all();
        const defs = {};
        for (const r of rows) {
          defs[r.revision_digest] = r.workflow_json;
        }
        if (Object.keys(defs).length > 0) {
          savePreservation(dataRoot, DOMAIN_ID, fromVer, toVer, { definitions: defs }, "Preserved schema 3 workflow routing");
        }
        db.exec("UPDATE strategy_meta SET value='2' WHERE key='version'");
      } finally {
        if (db) {
          try { db.close(); } catch {}
        }
      }
      return { converted: true, details: "downgraded adaptive flywheel to schema 2" };
    }
    return { converted: true, details: "database absent" };
  }

  if (fromVer === 1 && toVer === 0) {
    if (isRegularFileSync(dbPath)) {
      let db;
      try {
        db = new DatabaseSync(dbPath);
        const rows = db.prepare("SELECT * FROM strategy_definitions").all();
        savePreservation(dataRoot, DOMAIN_ID, fromVer, toVer, { definitions: rows }, "Preserved strategy definitions before removing SQLite DB");
      } catch {}
      finally {
        if (db) {
          try { db.close(); } catch {}
        }
      }
      // Write legacy toml placeholder if needed
      fs.writeFileSync(getLegacyTomlPath(dataRoot), "# adaptive-flywheel legacy\n", "utf8");
      removeFileSync(dbPath);
      return { converted: true, details: "downgraded adaptive flywheel to v0 legacy" };
    }
    return { converted: true, details: "database absent" };
  }

  if (fromVer === 2 && toVer === 0) {
    reverse(dataRoot, 2, 1);
    return reverse(dataRoot, 1, 0);
  }

  throw new Error(`Unsupported reverse migration edge for ${DOMAIN_ID}: ${fromVer} -> ${toVer}`);
}

export function verifyPostcondition(dataRoot, targetVersion) {
  const result = probe(dataRoot);
  if (result.present && result.version !== targetVersion) {
    throw new Error(`migration_postcondition_failed: ${DOMAIN_ID} expected version ${targetVersion}, observed ${result.version}`);
  }
  return true;
}
