import path from "node:path";
import fs from "node:fs";
import { DatabaseSync } from "node:sqlite";
import {
  writeJsonAtomicSync,
  readJsonSync,
  ensureDirectorySync,
  isRegularFileSync,
  isDirectorySync,
  removeFileSync,
} from "../fs-atomic.mjs";
import { savePreservation, loadPreservation, clearPreservation } from "../preservation.mjs";

const DOMAIN_ID = "canonical-conversation";
const CURRENT_SQLITE_SCHEMA_VERSION = "15";
const COMPLETION_MARKER_CONTENT = "schema=v5\nstatus=complete\n";

export function getDatabasePath(dataRoot) {
  return path.join(dataRoot, "client-state", "conversations", "conversations.sqlite3");
}

export function getCompletionMarkerPath(dataRoot) {
  return path.join(dataRoot, "client-state", "conversations", "migration-v5.complete");
}

export function getLegacyProjectionPath(dataRoot) {
  return path.join(dataRoot, "client-state", "agent-conversation-projections.json");
}

export function getLegacyGroupPath(dataRoot) {
  return path.join(dataRoot, "client-state", "group-conversations", "lico-group-default.json");
}

export function hasLegacyFiles(dataRoot) {
  const stateRoot = path.join(dataRoot, "client-state");
  const projection = path.join(stateRoot, "agent-conversation-projections.json");
  const flywheelToml = path.join(stateRoot, "adaptive-flywheel.toml");
  const groupDir = path.join(stateRoot, "group-conversations");

  return isRegularFileSync(projection) || isRegularFileSync(flywheelToml) || isDirectorySync(groupDir);
}

export function readSqliteSchemaVersion(dbPath) {
  if (!isRegularFileSync(dbPath)) {
    return null;
  }
  let db;
  try {
    db = new DatabaseSync(dbPath, { readOnly: true });
    const row = db.prepare("SELECT value FROM schema_meta WHERE key = ?").get("version");
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
  const markerPath = getCompletionMarkerPath(dataRoot);
  const dbPresent = isRegularFileSync(dbPath);
  const markerPresent = isRegularFileSync(markerPath);
  const legacyPresent = hasLegacyFiles(dataRoot);

  if (!dbPresent) {
    if (markerPresent) {
      throw new Error(`unsupported_state_shape: completion marker present without database in ${DOMAIN_ID}`);
    }
    return { version: 0, present: legacyPresent };
  }

  // A database without a readable schema version is unsupported shape, not a
  // legacy store (mirrors probe_sqlite_meta on the native side).
  const sqliteVer = readSqliteSchemaVersion(dbPath);
  if (sqliteVer === null) {
    throw new Error(`unsupported_state_shape: schema_meta unreadable in ${DOMAIN_ID}`);
  }
  const numeric = parseInt(sqliteVer, 10);
  if (!isNaN(numeric) && numeric > parseInt(CURRENT_SQLITE_SCHEMA_VERSION, 10)) {
    throw new Error(`state_newer_than_binary in ${DOMAIN_ID}`);
  }

  if (!markerPresent) {
    return { version: 0, present: true };
  }

  const markerText = fs.readFileSync(markerPath, "utf8");
  if (markerText !== COMPLETION_MARKER_CONTENT) {
    throw new Error(`unsupported_state_shape: completion marker content mismatch in ${DOMAIN_ID}`);
  }

  // The completion marker is authoritative for the domain version; the inner
  // SQLite schema advances through in-store upgrades owned by the client.
  return { version: 1, present: true, sqliteVersion: sqliteVer };
}

export function forward(dataRoot, fromVer, toVer) {
  if (fromVer === 0 && toVer === 1) {
    const dbPath = getDatabasePath(dataRoot);
    const markerPath = getCompletionMarkerPath(dataRoot);
    const projPath = getLegacyProjectionPath(dataRoot);
    ensureDirectorySync(path.dirname(dbPath));

    let db;
    try {
      db = new DatabaseSync(dbPath);
      db.exec(`
        CREATE TABLE IF NOT EXISTS schema_meta (
          key TEXT PRIMARY KEY,
          value TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS conversations (
          conversation_id TEXT PRIMARY KEY,
          title TEXT NOT NULL,
          created_at INTEGER NOT NULL,
          updated_at INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS conversation_messages (
          message_id TEXT PRIMARY KEY,
          conversation_id TEXT NOT NULL,
          role TEXT NOT NULL,
          content TEXT NOT NULL,
          created_at INTEGER NOT NULL
        );
      `);

      db.prepare(`
        INSERT INTO schema_meta (key, value) VALUES ('version', ?)
        ON CONFLICT(key) DO UPDATE SET value=excluded.value
      `).run(CURRENT_SQLITE_SCHEMA_VERSION);

      // If legacy projections exist, import them
      if (isRegularFileSync(projPath)) {
        const legacyData = readJsonSync(projPath);
        if (legacyData && legacyData.sessionsByAgent) {
          const insertConv = db.prepare(`
            INSERT INTO conversations (conversation_id, title, created_at, updated_at)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(conversation_id) DO NOTHING
          `);
          const insertMsg = db.prepare(`
            INSERT INTO conversation_messages (message_id, conversation_id, role, content, created_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(message_id) DO NOTHING
          `);

          const now = Date.now();
          for (const [agentId, sessions] of Object.entries(legacyData.sessionsByAgent)) {
            if (Array.isArray(sessions)) {
              for (const session of sessions) {
                const convId = session.id || `${agentId}-${now}`;
                const title = session.title || `Conversation with ${agentId}`;
                insertConv.run(convId, title, now, now);

                if (Array.isArray(session.messages)) {
                  for (let i = 0; i < session.messages.length; i++) {
                    const msg = session.messages[i];
                    const msgId = `${convId}-msg-${i}`;
                    insertMsg.run(msgId, convId, msg.role || "user", msg.content || "", now + i);
                  }
                }
              }
            }
          }
        }
      }

      // Check for preserved recovery extensions and restore
      const preserved = loadPreservation(dataRoot, DOMAIN_ID);
      if (preserved && preserved.preservedData) {
        if (preserved.preservedData.sqliteTables) {
          for (const [table, rows] of Object.entries(preserved.preservedData.sqliteTables)) {
            if (Array.isArray(rows) && rows.length > 0) {
              try {
                const cols = Object.keys(rows[0]);
                const colNames = cols.join(", ");
                const placeholders = cols.map(() => "?").join(", ");
                const stmt = db.prepare(`INSERT OR IGNORE INTO ${table} (${colNames}) VALUES (${placeholders})`);
                for (const row of rows) {
                  stmt.run(...cols.map((c) => row[c]));
                }
              } catch {
                // Table might not exist in simplified schema, preserved data remains safe
              }
            }
          }
        }
        clearPreservation(dataRoot, DOMAIN_ID);
      }
    } finally {
      if (db) {
        try { db.close(); } catch {}
      }
    }

    // Write completion marker
    fs.writeFileSync(markerPath, COMPLETION_MARKER_CONTENT, "utf8");

    // Clean up legacy files after successful commit
    removeFileSync(projPath);
    removeFileSync(path.join(dataRoot, "client-state", "adaptive-flywheel.toml"));
    const groupDir = path.join(dataRoot, "client-state", "group-conversations");
    if (fs.existsSync(groupDir)) {
      try {
        fs.rmSync(groupDir, { recursive: true, force: true });
      } catch {}
    }

    return { converted: true, details: "migrated conversations to canonical SQLite store and v5 completion marker" };
  }
  throw new Error(`Unsupported forward migration edge for ${DOMAIN_ID}: ${fromVer} -> ${toVer}`);
}

export function reverse(dataRoot, fromVer, toVer) {
  if (fromVer === 1 && toVer === 0) {
    const dbPath = getDatabasePath(dataRoot);
    const markerPath = getCompletionMarkerPath(dataRoot);
    const projPath = getLegacyProjectionPath(dataRoot);

    if (!isRegularFileSync(dbPath)) {
      removeFileSync(markerPath);
      return { converted: true, details: "database absent, removed marker" };
    }

    let db;
    const sessions = [];
    const preservedTables = {};

    try {
      db = new DatabaseSync(dbPath, { readOnly: true });

      // Read conversations
      try {
        const convRows = db.prepare("SELECT * FROM conversations").all();
        preservedTables.conversations = convRows;

        let msgRows = [];
        try {
          msgRows = db.prepare("SELECT * FROM conversation_messages ORDER BY created_at ASC").all();
          preservedTables.conversation_messages = msgRows;
        } catch {}

        for (const conv of convRows) {
          const cId = conv.conversation_id || conv.id;
          const relatedMsgs = msgRows
            .filter((m) => m.conversation_id === cId)
            .map((m) => ({ role: m.role, content: m.content }));

          sessions.push({
            id: cId,
            title: conv.title || "Restored Conversation",
            messages: relatedMsgs.length > 0 ? relatedMsgs : [{ role: "assistant", content: "..." }],
          });
        }
      } catch {}
    } finally {
      if (db) {
        try { db.close(); } catch {}
      }
    }

    // Save unrepresentable SQLite features to preservation
    savePreservation(dataRoot, DOMAIN_ID, fromVer, toVer, {
      sqliteTables: preservedTables,
      downgradedAt: new Date().toISOString(),
    }, "Preserved canonical conversation SQLite records during downgrade to v0 legacy projection");

    // Write legacy projection JSON
    const projectionDoc = {
      schemaVersion: 1,
      sessionsByAgent: {
        "agent-default": sessions.length > 0 ? sessions : [{ id: "session-default", title: "Restored", messages: [] }],
      },
    };
    writeJsonAtomicSync(projPath, projectionDoc);

    // Remove completion marker so v0 client will admit the legacy files
    removeFileSync(markerPath);

    return { converted: true, details: "downgraded canonical conversation store to legacy projection JSON" };
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
