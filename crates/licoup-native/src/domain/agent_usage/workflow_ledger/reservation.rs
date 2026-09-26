//! Durable budget reservation state, transitions, and persistence.

use super::*;
use crate::state_machines::workflow_budget_reservation::{
    self as reservation_machine, Event as ReservationEvent, State as ReservationState,
};

#[derive(Clone, Debug)]
pub(super) struct ReservationRow {
    pub(super) invocation_id: String,
    pub(super) budget_id: String,
    pub(super) run_id: Option<String>,
    pub(super) command_id: Option<String>,
    pub(super) estimate_accuracy: UsageAccuracy,
    pub(super) estimated_tokens: Option<u64>,
    pub(super) reserved_tokens: u64,
    pub(super) state: ReservationState,
    pub(super) settlement_status: Option<String>,
    pub(super) usage: Option<CheckedUsage>,
    pub(super) overage_tokens: u64,
}

#[derive(Clone, Copy, Debug, Default)]
pub(super) struct ActiveReservationStats {
    pub(super) reserved_tokens: u64,
    pub(super) in_flight_count: u64,
    pub(super) unknown_count: u64,
}

/// Atomically reserve one locally admitted, chargeable invocation from a
/// budget pool. The pool snapshot is an admission input, not a provider
/// billing guarantee: estimates can protect LicoUp's own concurrent work but
/// cannot cap calls made internally by an external Agent.
pub fn reserve_graph_command(params: &Value) -> LedgerResult<Value> {
    let invocation_id = required_invocation_id(params)?;
    let run_id = optional_id(params, "runId")?;
    let command_id = optional_id(params, "commandId")?;
    let (budget_id, budget_snapshot) = parse_budget(params)?;
    let estimate = parse_usage_estimate(params)?;
    let chargeable = chargeable(params)?;
    let mut ledger = open_ledger(params)?;
    let transaction = ledger
        .connection
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(|_| LedgerError::storage())?;

    if let Some(existing) = load_reservation(&transaction, &invocation_id)? {
        ensure_reservation_identity(
            &existing,
            &budget_id,
            run_id.as_deref(),
            command_id.as_deref(),
        )?;
        if existing.estimated_tokens != estimate.total_tokens
            || existing.estimate_accuracy != estimate.accuracy
        {
            return Err(LedgerError::invalid(
                "usage_ledger_reservation_request_conflict",
            ));
        }
        let pool = load_or_update_budget_pool(&transaction, &budget_id, budget_snapshot)?;
        let active = active_reservation_stats(&transaction, &budget_id)?;
        let available = available_tokens(&pool, active);
        transaction.commit().map_err(|_| LedgerError::storage())?;
        return Ok(reservation_admission_value(
            &existing,
            &pool,
            active,
            available,
            true,
            matches!(
                existing.state,
                ReservationState::Reserved | ReservationState::Unknown
            ),
        ));
    }

    let pool = load_or_update_budget_pool(&transaction, &budget_id, budget_snapshot)?;
    let active = active_reservation_stats(&transaction, &budget_id)?;
    let available = available_tokens(&pool, active);

    if !chargeable {
        transaction.commit().map_err(|_| LedgerError::storage())?;
        return Ok(json!({
            "ok": true,
            "invocationId": invocation_id,
            "budgetId": budget_id,
            "admitted": true,
            "state": "free",
            "admissionMode": "free-read",
            "hardCapGuaranteed": false,
            "budget": budget_value(&pool, active, available),
        }));
    }

    let exhausted = available.is_some_and(|available| available == 0);
    let exceeds_remaining = available.is_some_and(|available| {
        estimate
            .total_tokens
            .is_some_and(|estimate| estimate > available)
    });
    let denied = exhausted || exceeds_remaining;
    if denied {
        let code = if exhausted {
            "budget_exhausted"
        } else {
            "budget_reservation_exceeds_remaining"
        };
        transaction.commit().map_err(|_| LedgerError::storage())?;
        return Ok(json!({
            "ok": true,
            "invocationId": invocation_id,
            "budgetId": budget_id,
            "admitted": false,
            "state": "waiting-budget",
            "code": code,
            "admissionMode": if estimate.total_tokens.is_some() { "estimate-only" } else { "unknown-estimate" },
            "hardCapGuaranteed": false,
            "prompt": {
                "code": "budget_adjustment_required",
                "recovery": "adjust_budget_and_resume",
                "keepsInFlight": true,
                "stopsNewDispatch": exhausted,
            },
            "estimate": estimate_value(estimate),
            "budget": budget_value(&pool, active, available),
        }));
    }

    let reserved_tokens = estimate.total_tokens.unwrap_or(0);
    let now = now_ms();
    transaction
        .execute(
            "INSERT INTO graph_usage_reservations(
               invocation_id,budget_id,run_id,command_id,estimate_accuracy,
               estimated_tokens,reserved_tokens,state,created_at_ms,updated_at_ms
             ) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?9)",
            params![
                &invocation_id,
                &budget_id,
                run_id.as_deref(),
                command_id.as_deref(),
                estimate.accuracy.as_str(),
                sqlite_optional_u64(estimate.total_tokens, "usage_ledger_counter_overflow",)?,
                sqlite_u64(reserved_tokens, "usage_ledger_counter_overflow")?,
                reservation_machine::INITIAL.as_str(),
                now,
            ],
        )
        .map_err(|_| LedgerError::storage())?;
    let reservation =
        load_reservation(&transaction, &invocation_id)?.ok_or_else(LedgerError::storage)?;
    let active = active_reservation_stats(&transaction, &budget_id)?;
    let available = available_tokens(&pool, active);
    transaction.commit().map_err(|_| LedgerError::storage())?;
    Ok(reservation_admission_value(
        &reservation,
        &pool,
        active,
        available,
        false,
        true,
    ))
}

/// Settle one reservation against its original invocation identity. A result
/// without usage is retained as unknown and continues to occupy its numeric
/// estimate until a later reconciliation supplies usage for the same id.
pub fn settle_graph_command(params: &Value) -> LedgerResult<Value> {
    let invocation_id = required_invocation_id(params)?;
    let run_id = optional_id(params, "runId")?;
    let command_id = optional_id(params, "commandId")?;
    let requested_budget_id = optional_budget_id(params)?;
    let usage = parse_settlement_usage(params)?;
    let settlement_status = parse_settlement_status(params, usage.is_some())?;
    let mut ledger = open_ledger(params)?;
    let transaction = ledger
        .connection
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(|_| LedgerError::storage())?;
    let existing = load_reservation(&transaction, &invocation_id)?
        .ok_or_else(|| LedgerError::invalid("usage_ledger_reservation_not_found"))?;
    ensure_reservation_identity(
        &existing,
        requested_budget_id
            .as_deref()
            .unwrap_or(&existing.budget_id),
        run_id.as_deref(),
        command_id.as_deref(),
    )?;

    if existing.state == ReservationState::Released {
        return Err(LedgerError::invalid("usage_ledger_reservation_released"));
    }
    if existing.state == ReservationState::Settled {
        if let Some(usage) = usage
            && existing.usage != Some(usage)
        {
            return Err(LedgerError::invalid("usage_ledger_settlement_conflict"));
        }
        let active = active_reservation_stats(&transaction, &existing.budget_id)?;
        let pool = load_or_update_budget_pool(
            &transaction,
            &existing.budget_id,
            BudgetSnapshot::default(),
        )?;
        let available = available_tokens(&pool, active);
        transaction.commit().map_err(|_| LedgerError::storage())?;
        return Ok(settlement_value(
            &existing, &pool, active, available, false, true,
        ));
    }

    let was_unknown = existing.state == ReservationState::Unknown;
    let event = if usage.is_some() {
        ReservationEvent::SettleKnown
    } else {
        ReservationEvent::SettleUnknown
    };
    let target = reservation_machine::transition(existing.state, event)
        .ok_or_else(|| LedgerError::invalid("usage_ledger_state_invalid"))?;
    if let Some(usage) = usage {
        let overage = usage.total.saturating_sub(existing.reserved_tokens);
        let pool = load_or_update_budget_pool(
            &transaction,
            &existing.budget_id,
            BudgetSnapshot::default(),
        )?;
        let actual_tokens = pool
            .actual_tokens
            .checked_add(usage.total)
            .ok_or_else(|| LedgerError::invalid("usage_ledger_counter_overflow"))?;
        let now = now_ms();
        transaction
            .execute(
                "UPDATE graph_usage_reservations SET
                   state=?2,settlement_status=?3,prompt_tokens=?4,
                   cached_input_tokens=?5,completion_tokens=?6,total_tokens=?7,
                   usage_accuracy=?8,overage_tokens=?9,updated_at_ms=?10
                 WHERE invocation_id=?1",
                params![
                    invocation_id,
                    target.as_str(),
                    settlement_status,
                    sqlite_u64(usage.prompt, "usage_ledger_counter_overflow")?,
                    sqlite_u64(usage.cached, "usage_ledger_counter_overflow")?,
                    sqlite_u64(usage.completion, "usage_ledger_counter_overflow")?,
                    sqlite_u64(usage.total, "usage_ledger_counter_overflow")?,
                    usage.accuracy.as_str(),
                    sqlite_u64(overage, "usage_ledger_counter_overflow")?,
                    now,
                ],
            )
            .map_err(|_| LedgerError::storage())?;
        transaction
            .execute(
                "UPDATE graph_usage_budget_pools SET actual_tokens=?2,updated_at_ms=?3
                 WHERE budget_id=?1",
                params![
                    existing.budget_id,
                    sqlite_u64(actual_tokens, "usage_ledger_counter_overflow")?,
                    now,
                ],
            )
            .map_err(|_| LedgerError::storage())?;
    } else {
        let now = now_ms();
        transaction
            .execute(
                "UPDATE graph_usage_reservations SET
                   state=?2,settlement_status=COALESCE(settlement_status,?3),
                   updated_at_ms=?4 WHERE invocation_id=?1",
                params![invocation_id, target.as_str(), settlement_status, now],
            )
            .map_err(|_| LedgerError::storage())?;
    }

    let settled =
        load_reservation(&transaction, &invocation_id)?.ok_or_else(LedgerError::storage)?;
    let pool =
        load_or_update_budget_pool(&transaction, &settled.budget_id, BudgetSnapshot::default())?;
    let active = active_reservation_stats(&transaction, &settled.budget_id)?;
    let available = available_tokens(&pool, active);
    transaction.commit().map_err(|_| LedgerError::storage())?;
    Ok(settlement_value(
        &settled,
        &pool,
        active,
        available,
        was_unknown,
        false,
    ))
}

/// Release a reservation that was admitted but never started. An unknown
/// external outcome is deliberately not releasable: it must settle or remain
/// in the reconciliation balance.
pub fn release_graph_command(params: &Value) -> LedgerResult<Value> {
    let invocation_id = required_invocation_id(params)?;
    let requested_budget_id = optional_budget_id(params)?;
    let mut ledger = open_ledger(params)?;
    let transaction = ledger
        .connection
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(|_| LedgerError::storage())?;
    let existing = load_reservation(&transaction, &invocation_id)?
        .ok_or_else(|| LedgerError::invalid("usage_ledger_reservation_not_found"))?;
    if requested_budget_id
        .as_deref()
        .is_some_and(|budget_id| budget_id != existing.budget_id)
    {
        return Err(LedgerError::invalid(
            "usage_ledger_reservation_identity_conflict",
        ));
    }
    if existing.state == ReservationState::Unknown {
        return Err(LedgerError::invalid("usage_ledger_unknown_not_releasable"));
    }
    if let Some(target) = reservation_machine::transition(existing.state, ReservationEvent::Release)
    {
        transaction
            .execute(
                "UPDATE graph_usage_reservations SET state=?2,
                 settlement_status='not-started',updated_at_ms=?3 WHERE invocation_id=?1",
                params![invocation_id, target.as_str(), now_ms()],
            )
            .map_err(|_| LedgerError::storage())?;
    } else if !reservation_machine::terminal(existing.state) {
        return Err(LedgerError::invalid("usage_ledger_state_invalid"));
    }
    let released =
        load_reservation(&transaction, &invocation_id)?.ok_or_else(LedgerError::storage)?;
    let pool =
        load_or_update_budget_pool(&transaction, &released.budget_id, BudgetSnapshot::default())?;
    let active = active_reservation_stats(&transaction, &released.budget_id)?;
    let available = available_tokens(&pool, active);
    transaction.commit().map_err(|_| LedgerError::storage())?;
    Ok(json!({
        "ok": true,
        "invocationId": released.invocation_id,
        "budgetId": released.budget_id,
        "state": released.state.as_str(),
        "released": true,
        "budget": budget_value(&pool, active, available),
    }))
}

pub(super) fn active_reservation_stats(
    connection: &Connection,
    budget_id: &str,
) -> LedgerResult<ActiveReservationStats> {
    connection
        .query_row(
            "SELECT COALESCE(SUM(reserved_tokens),0),
                    COUNT(*),
                    COALESCE(SUM(CASE WHEN state='unknown' THEN 1 ELSE 0 END),0)
             FROM graph_usage_reservations
             WHERE budget_id=?1 AND state IN ('reserved','unknown')",
            params![budget_id],
            |row| {
                Ok((
                    row.get::<_, i64>(0)?,
                    row.get::<_, i64>(1)?,
                    row.get::<_, i64>(2)?,
                ))
            },
        )
        .map_err(|_| LedgerError::storage())
        .and_then(|(reserved_tokens, in_flight_count, unknown_count)| {
            Ok(ActiveReservationStats {
                reserved_tokens: u64::try_from(reserved_tokens)
                    .map_err(|_| LedgerError::invalid("usage_ledger_storage_invalid"))?,
                in_flight_count: u64::try_from(in_flight_count)
                    .map_err(|_| LedgerError::invalid("usage_ledger_storage_invalid"))?,
                unknown_count: u64::try_from(unknown_count)
                    .map_err(|_| LedgerError::invalid("usage_ledger_storage_invalid"))?,
            })
        })
}

fn reservation_admission_value(
    reservation: &ReservationRow,
    pool: &BudgetPool,
    active: ActiveReservationStats,
    available: Option<u64>,
    reused: bool,
    admitted: bool,
) -> Value {
    json!({
        "ok": true,
        "invocationId": reservation.invocation_id,
        "budgetId": reservation.budget_id,
        "admitted": admitted,
        "state": reservation.state.as_str(),
        "reused": reused,
        "admissionMode": if reservation.estimated_tokens.is_some() { "estimate-only" } else { "unknown-estimate" },
        "hardCapGuaranteed": false,
        "estimate": {
            "totalTokens": reservation.estimated_tokens,
            "accuracy": reservation.estimate_accuracy.as_str(),
        },
        "reservedTokens": reservation.reserved_tokens,
        "budget": budget_value(pool, active, available),
    })
}

fn settlement_value(
    reservation: &ReservationRow,
    pool: &BudgetPool,
    active: ActiveReservationStats,
    available: Option<u64>,
    late: bool,
    idempotent: bool,
) -> Value {
    json!({
        "ok": true,
        "invocationId": reservation.invocation_id,
        "budgetId": reservation.budget_id,
        "state": reservation.state.as_str(),
        "settled": reservation.state == ReservationState::Settled,
        "reconciliationRequired": reservation.state == ReservationState::Unknown,
        "late": late,
        "idempotent": idempotent,
        "settlementStatus": reservation.settlement_status,
        "usage": reservation.usage.map(CheckedUsage::to_value),
        "usageAccuracy": reservation.usage.map(|usage| usage.accuracy.as_str()),
        "reservedTokens": reservation.reserved_tokens,
        "overageTokens": reservation.overage_tokens,
        "budget": budget_value(pool, active, available),
    })
}

fn ensure_reservation_identity(
    reservation: &ReservationRow,
    budget_id: &str,
    run_id: Option<&str>,
    command_id: Option<&str>,
) -> LedgerResult<()> {
    if reservation.budget_id != budget_id
        || run_id.is_some_and(|run_id| reservation.run_id.as_deref() != Some(run_id))
        || command_id
            .is_some_and(|command_id| reservation.command_id.as_deref() != Some(command_id))
    {
        return Err(LedgerError::invalid(
            "usage_ledger_reservation_identity_conflict",
        ));
    }
    Ok(())
}

pub(super) fn reservation_value(reservation: &ReservationRow) -> Value {
    json!({
        "invocationId": reservation.invocation_id,
        "budgetId": reservation.budget_id,
        "runId": reservation.run_id,
        "commandId": reservation.command_id,
        "state": reservation.state.as_str(),
        "estimateAccuracy": reservation.estimate_accuracy.as_str(),
        "estimatedTokens": reservation.estimated_tokens,
        "reservedTokens": reservation.reserved_tokens,
        "settlementStatus": reservation.settlement_status,
        "usage": reservation.usage.map(CheckedUsage::to_value),
        "overageTokens": reservation.overage_tokens,
    })
}

struct RawReservationRow {
    invocation_id: String,
    budget_id: String,
    run_id: Option<String>,
    command_id: Option<String>,
    estimate_accuracy: String,
    estimated_tokens: Option<i64>,
    reserved_tokens: i64,
    state: String,
    settlement_status: Option<String>,
    prompt_tokens: Option<i64>,
    cached_input_tokens: Option<i64>,
    completion_tokens: Option<i64>,
    total_tokens: Option<i64>,
    usage_accuracy: Option<String>,
    overage_tokens: i64,
}

fn load_reservation(
    connection: &Connection,
    invocation_id: &str,
) -> LedgerResult<Option<ReservationRow>> {
    let raw = connection
        .query_row(
            "SELECT invocation_id,budget_id,run_id,command_id,estimate_accuracy,
                    estimated_tokens,reserved_tokens,state,settlement_status,
                    prompt_tokens,cached_input_tokens,completion_tokens,total_tokens,
                    usage_accuracy,overage_tokens
             FROM graph_usage_reservations WHERE invocation_id=?1",
            params![invocation_id],
            raw_reservation_from_row,
        )
        .optional()
        .map_err(|_| LedgerError::storage())?;
    raw.map(decode_reservation).transpose()
}

pub(super) fn load_reservations(
    connection: &Connection,
    run_id: Option<&str>,
) -> LedgerResult<Vec<ReservationRow>> {
    let mut statement = connection
        .prepare(
            "SELECT invocation_id,budget_id,run_id,command_id,estimate_accuracy,
                    estimated_tokens,reserved_tokens,state,settlement_status,
                    prompt_tokens,cached_input_tokens,completion_tokens,total_tokens,
                    usage_accuracy,overage_tokens
             FROM graph_usage_reservations
             WHERE (?1 IS NULL OR run_id=?1)
             ORDER BY updated_at_ms DESC,invocation_id DESC",
        )
        .map_err(|_| LedgerError::storage())?;
    let rows = statement
        .query_map(params![run_id], raw_reservation_from_row)
        .map_err(|_| LedgerError::storage())?;
    let mut reservations = Vec::new();
    for row in rows {
        let raw = row.map_err(|_| LedgerError::storage())?;
        reservations.push(decode_reservation(raw)?);
    }
    Ok(reservations)
}

fn raw_reservation_from_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<RawReservationRow> {
    Ok(RawReservationRow {
        invocation_id: row.get(0)?,
        budget_id: row.get(1)?,
        run_id: row.get(2)?,
        command_id: row.get(3)?,
        estimate_accuracy: row.get(4)?,
        estimated_tokens: row.get(5)?,
        reserved_tokens: row.get(6)?,
        state: row.get(7)?,
        settlement_status: row.get(8)?,
        prompt_tokens: row.get(9)?,
        cached_input_tokens: row.get(10)?,
        completion_tokens: row.get(11)?,
        total_tokens: row.get(12)?,
        usage_accuracy: row.get(13)?,
        overage_tokens: row.get(14)?,
    })
}

fn decode_reservation(raw: RawReservationRow) -> LedgerResult<ReservationRow> {
    let estimate_accuracy = stored_accuracy(&raw.estimate_accuracy)?;
    let estimated_tokens = from_sqlite_u64(raw.estimated_tokens)?;
    let reserved_tokens = u64::try_from(raw.reserved_tokens)
        .map_err(|_| LedgerError::invalid("usage_ledger_storage_invalid"))?;
    let overage_tokens = u64::try_from(raw.overage_tokens)
        .map_err(|_| LedgerError::invalid("usage_ledger_storage_invalid"))?;
    let usage = match raw.total_tokens {
        None => None,
        Some(_) => Some(CheckedUsage {
            prompt: from_sqlite_u64(raw.prompt_tokens)?.unwrap_or(0),
            cached: from_sqlite_u64(raw.cached_input_tokens)?.unwrap_or(0),
            completion: from_sqlite_u64(raw.completion_tokens)?.unwrap_or(0),
            total: from_sqlite_u64(raw.total_tokens)?.unwrap_or(0),
            accuracy: stored_accuracy(raw.usage_accuracy.as_deref().unwrap_or("unknown"))?,
        }),
    };
    Ok(ReservationRow {
        invocation_id: raw.invocation_id,
        budget_id: raw.budget_id,
        run_id: raw.run_id,
        command_id: raw.command_id,
        estimate_accuracy,
        estimated_tokens,
        reserved_tokens,
        state: ReservationState::from_name(&raw.state)
            .ok_or_else(|| LedgerError::invalid("usage_ledger_storage_invalid"))?,
        settlement_status: raw.settlement_status,
        usage,
        overage_tokens,
    })
}
