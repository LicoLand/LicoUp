//! Checkpoint admission: which checkpoints this build may advance at all.
//!
//! The causal-input contract allows three continuations for an older run — a
//! compatible interpreter, a tested migration, or the previous instance until a
//! safe handoff point — and forbids one: silently advancing it under the current
//! interpreter. Each test here stages a real checkpoint in a shape a real
//! database could hold and asserts the admission answer, not a code path.

use anyhow::Result;
use licoup_workflow_runtime::successor::recovery::{
    CheckpointAdmission, CheckpointHandoff, RecoveryCause, RecoveryPort, RecoveryRequest,
};

use crate::support::{self, Fixture};

fn request(run_id: &str) -> RecoveryRequest {
    RecoveryRequest {
        run_id: run_id.to_owned(),
        cause: RecoveryCause::LeaseLapsed,
        now_unix_ms: support::now_ms(),
    }
}

#[test]
fn a_current_checkpoint_is_admitted_and_the_sweep_runs() -> Result<()> {
    let fixture = Fixture::with_definition("admit-current", "run-1", &support::single_actor())?;
    fixture.start("run-1")?;
    let recovery = fixture.recovery();

    assert_eq!(
        recovery.checkpoint_admission("run-1")?,
        CheckpointAdmission::Advance
    );
    let report = recovery.sweep(&request("run-1"))?;
    assert_eq!(report.block, None);
    assert_eq!(report.considered, 1, "the queued attempt was considered");
    Ok(())
}

#[test]
fn a_checkpoint_without_causal_state_is_handed_off() -> Result<()> {
    let fixture = Fixture::with_definition("admit-causal", "run-1", &support::single_actor())?;
    fixture.start("run-1")?;
    let recovery = fixture.recovery();
    fixture.rewrite_snapshot("run-1", |value| {
        value
            .as_object_mut()
            .expect("the checkpoint is an object")
            .remove("stateVisits")
            .is_some()
    })?;

    assert_eq!(
        recovery.checkpoint_admission("run-1")?,
        CheckpointAdmission::Handoff {
            reason: CheckpointHandoff::CausalStateMissing
        }
    );
    let report = recovery.sweep(&request("run-1"))?;
    assert!(report.block.is_some());
    assert_eq!(report.considered, 0, "nothing was decided");
    Ok(())
}

#[test]
fn a_checkpoint_projected_by_another_input_adapter_is_handed_off() -> Result<()> {
    let fixture = Fixture::with_definition("admit-adapter", "run-1", &support::single_actor())?;
    fixture.start("run-1")?;
    fixture.rewrite_snapshot("run-1", |value| {
        let plan = value
            .get_mut("inputPlan")
            .and_then(|plan| plan.as_object_mut())
            .expect("the input plan is an object");
        plan.insert(
            "inputAdapterVersion".into(),
            serde_json::json!(licoup_workflow::INPUT_ADAPTER_VERSION + 1),
        );
        true
    })?;

    assert_eq!(
        fixture.recovery().checkpoint_admission("run-1")?,
        CheckpointAdmission::Handoff {
            reason: CheckpointHandoff::InputAdapterMismatch
        }
    );
    Ok(())
}

#[test]
fn a_checkpoint_whose_definition_is_missing_is_handed_off() -> Result<()> {
    let fixture = Fixture::with_definition("admit-definition", "run-1", &support::single_actor())?;
    fixture.start("run-1")?;
    // The store's own schema references the definition from the run, so the row
    // cannot be removed through the store's pragmas. A file can still be in
    // this state — restored, pruned, or written by a build whose foreign keys
    // were off — so the staging opens its own connection with enforcement off,
    // which is exactly the file admission has to answer about.
    {
        let connection = rusqlite::Connection::open(fixture.path())?;
        connection.execute_batch("PRAGMA foreign_keys=OFF")?;
        connection.execute(
            "DELETE FROM strategy_definitions WHERE revision_digest=?1",
            rusqlite::params![fixture.revision_digest()],
        )?;
    }

    assert_eq!(
        fixture.recovery().checkpoint_admission("run-1")?,
        CheckpointAdmission::Handoff {
            reason: CheckpointHandoff::DefinitionMissing
        }
    );
    Ok(())
}

#[test]
fn a_malformed_checkpoint_is_refused_not_handed_off() -> Result<()> {
    let fixture = Fixture::with_definition("admit-malformed", "run-1", &support::single_actor())?;
    fixture.start("run-1")?;
    fixture.set_snapshot_json("run-1", "{ this is not a checkpoint")?;

    let admission = fixture.recovery().checkpoint_admission("run-1")?;
    assert!(
        matches!(
            admission,
            CheckpointAdmission::Refused { ref code } if code == "workflow_run_checkpoint_invalid"
        ),
        "unexpected admission: {admission:?}"
    );
    Ok(())
}

#[test]
fn a_run_whose_recorded_semantics_moved_is_refused() -> Result<()> {
    let fixture = Fixture::with_definition("admit-semantics", "run-1", &support::single_actor())?;
    fixture.start("run-1")?;
    // The run was admitted under one semantics and the definition row it names
    // now declares another: continuing would silently rebind the run.
    fixture.set_run_semantics("run-1", "semantics-fixture-v2")?;

    let admission = fixture.recovery().checkpoint_admission("run-1")?;
    assert!(
        matches!(
            admission,
            CheckpointAdmission::Refused { ref code }
                if code == "workflow_checkpoint_semantics_mismatch"
        ),
        "unexpected admission: {admission:?}"
    );
    Ok(())
}

#[test]
fn a_missing_run_is_refused_by_name() -> Result<()> {
    let fixture = Fixture::with_definition("admit-missing", "run-1", &support::single_actor())?;
    let admission = fixture
        .recovery()
        .checkpoint_admission("run-that-never-existed")?;
    assert_eq!(
        admission,
        CheckpointAdmission::Refused {
            code: "workflow_run_not_found".into()
        }
    );
    Ok(())
}
