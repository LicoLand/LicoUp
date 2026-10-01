use super::*;

#[test]
fn continuity_owner_contract_is_valid_and_partial_or_changed_effects_are_refused() {
    const CONTINUITY: &str =
        include_str!("../../../../../tests/fixtures/client_state_migration/continuity_current.sql");
    for mutation in [
        None,
        Some("DROP TRIGGER continuity_bump_designation_epoch;"),
        Some(
            "DROP TRIGGER continuity_bump_designation_epoch; CREATE TRIGGER continuity_bump_designation_epoch AFTER UPDATE OF assistant_membership_id ON conversations BEGIN DELETE FROM conversations WHERE id=NEW.id; END;",
        ),
        Some(
            "CREATE TRIGGER extra_effect BEFORE INSERT ON conversations BEGIN SELECT RAISE(ABORT, 'blocked'); END;",
        ),
        Some("DROP TABLE continuity_goals;"),
        Some("DELETE FROM continuity_schema WHERE key='version';"),
    ] {
        let mut connection = Connection::open_in_memory().unwrap();
        create_current_schema(&mut connection).unwrap();
        connection.execute_batch(CONTINUITY).unwrap();
        if let Some(sql) = mutation {
            connection.execute_batch(sql).unwrap();
        }
        let before = layout(&connection);
        if mutation.is_some() {
            assert!(preflight_schema(&connection).is_err());
        } else {
            preflight_schema(&connection).unwrap();
        }
        assert_eq!(layout(&connection), before);
    }
    let mut connection = Connection::open_in_memory().unwrap();
    create_current_schema(&mut connection).unwrap();
    connection.execute_batch("CREATE TABLE continuity_schema(key TEXT PRIMARY KEY,value TEXT NOT NULL); INSERT INTO continuity_schema VALUES ('version','7');").unwrap();
    let before = layout(&connection);
    assert!(preflight_schema(&connection).is_err());
    assert_eq!(layout(&connection), before);
}

fn version(connection: &Connection) -> String {
    connection
        .query_row(
            "SELECT value FROM schema_meta WHERE key='version'",
            [],
            |row| row.get(0),
        )
        .unwrap()
}

fn layout(connection: &Connection) -> Vec<(String, String)> {
    connection
        .prepare("SELECT name, sql FROM sqlite_schema WHERE sql IS NOT NULL ORDER BY name")
        .unwrap()
        .query_map([], |row| Ok((row.get(0)?, row.get(1)?)))
        .unwrap()
        .collect::<rusqlite::Result<_>>()
        .unwrap()
}

#[test]
fn published_upgrade_is_atomic_and_preserves_conversation_content() {
    let mut connection = Connection::open_in_memory().unwrap();
    initialize_schema(&mut connection).unwrap();
    connection.execute_batch(
        "INSERT INTO principals VALUES ('agent', 'agent', 'Synthetic agent', 'synthetic', 1);
         INSERT INTO conversations(id,title,created_at,updated_at) VALUES ('conversation','Synthetic conversation',1,1);
         INSERT INTO memberships VALUES ('member','conversation','agent','member','active',1,NULL);
         INSERT INTO membership_profiles(membership_id,revision,responsibility,skill_references,updated_at)
           VALUES ('member',3,'assistant','[\"assistant-workflow-authoring\",\"custom-skill\"]',1);
         INSERT INTO events(id,conversation_id,sequence,kind,created_at,finalized)
           VALUES ('event','conversation',1,'message',1,1);
         INSERT INTO event_parts(id,event_id,ordinal,kind,content,created_at)
           VALUES ('part','event',0,'text','Synthetic retained message',1);
         INSERT INTO source_links VALUES ('link','conversation','agent-runtime','9:synthetic:session');
         DROP TABLE conversation_native_sessions;
         DROP TABLE archived_native_sessions;
         DROP TABLE subagent_dispatch_deliveries;
         DROP INDEX conversation_dispatches_native_provenance_idx;
         ALTER TABLE conversation_dispatches DROP COLUMN native_provenance;
         ALTER TABLE conversation_dispatches DROP COLUMN request_payload;
         ALTER TABLE conversation_dispatches DROP COLUMN terminal_payload;
         ALTER TABLE event_parts DROP COLUMN execution_kind;
         UPDATE schema_meta SET value='12' WHERE key='version';
         CREATE TRIGGER fail_upgrade BEFORE UPDATE ON schema_meta
           BEGIN SELECT RAISE(ABORT, 'synthetic interrupted upgrade'); END;",
    ).unwrap();
    let before = layout(&connection);
    assert!(initialize_schema(&mut connection).is_err());
    assert_eq!(version(&connection), "12");
    assert_eq!(layout(&connection), before);
    let revision: i64 = connection
        .query_row(
            "SELECT revision FROM membership_profiles WHERE membership_id='member'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(revision, 3);

    connection
        .execute_batch("DROP TRIGGER fail_upgrade;")
        .unwrap();
    initialize_schema(&mut connection).unwrap();
    assert_eq!(version(&connection), CURRENT_SCHEMA_VERSION);
    let content: String = connection
        .query_row(
            "SELECT content FROM event_parts WHERE id='part' AND event_id='event'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(content, "Synthetic retained message");
    let profile: (i64, String) = connection.query_row(
        "SELECT revision, skill_references FROM membership_profiles WHERE membership_id='member'", [], |row| Ok((row.get(0)?,row.get(1)?)),
    ).unwrap();
    assert_eq!(profile.0, 4);
    assert_eq!(
        serde_json::from_str::<Vec<String>>(&profile.1).unwrap(),
        ["custom-skill", LICOUP_GUIDE_SKILL_ID]
    );
    let session: String = connection.query_row(
        "SELECT native_session_id FROM conversation_native_sessions WHERE conversation_id='conversation' AND membership_id='member'", [], |row| row.get(0),
    ).unwrap();
    assert_eq!(session, "session");
    let indexed: i64 = connection
        .query_row(
            "SELECT COUNT(*) FROM event_search WHERE event_search MATCH 'retained'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(indexed, 1);
    let after = layout(&connection);
    initialize_schema(&mut connection).unwrap();
    assert_eq!(layout(&connection), after);
    let revision: i64 = connection
        .query_row(
            "SELECT revision FROM membership_profiles WHERE membership_id='member'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(revision, 4);
}

#[test]
fn unsupported_schema_versions_are_rejected_before_schema_writes() {
    for unsupported in ["13", "14", "15", "16", "17", "999"] {
        let mut connection = Connection::open_in_memory().unwrap();
        connection
            .execute_batch("CREATE TABLE schema_meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);")
            .unwrap();
        connection
            .execute(
                "INSERT INTO schema_meta VALUES ('version', ?1)",
                [unsupported],
            )
            .unwrap();
        let before = layout(&connection);
        assert!(
            initialize_schema(&mut connection).is_err(),
            "version {unsupported}"
        );
        assert_eq!(version(&connection), unsupported);
        assert_eq!(layout(&connection), before);
    }
}

#[test]
fn missing_schema_version_is_rejected_without_writes() {
    let mut connection = Connection::open_in_memory().unwrap();
    connection
        .execute_batch(
            "CREATE TABLE schema_meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
             INSERT INTO schema_meta VALUES ('format', 'synthetic');",
        )
        .unwrap();
    let before = layout(&connection);
    assert!(initialize_schema(&mut connection).is_err());
    assert_eq!(layout(&connection), before);
}

#[test]
fn application_tables_without_schema_metadata_are_rejected_without_writes() {
    let mut connection = Connection::open_in_memory().unwrap();
    connection
        .execute_batch(
            "CREATE TABLE retained_fixture(value TEXT NOT NULL);
             INSERT INTO retained_fixture VALUES ('synthetic retained data');",
        )
        .unwrap();
    let before = layout(&connection);
    assert!(initialize_schema(&mut connection).is_err());
    assert_eq!(layout(&connection), before);
    let retained: String = connection
        .query_row("SELECT value FROM retained_fixture", [], |row| row.get(0))
        .unwrap();
    assert_eq!(retained, "synthetic retained data");
}

#[test]
fn fresh_and_current_schemas_initialize_idempotently() {
    let mut connection = Connection::open_in_memory().unwrap();
    initialize_schema(&mut connection).unwrap();
    assert_eq!(version(&connection), CURRENT_SCHEMA_VERSION);
    let current_layout = layout(&connection);
    initialize_schema(&mut connection).unwrap();
    assert_eq!(layout(&connection), current_layout);
}
