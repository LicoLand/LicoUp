//! Usage time-window and timezone projection.

use super::contract::{DEFAULT_USAGE_WINDOW_DAYS, number_value};
use crate::domain::conversation::parameters::text_param;
use serde_json::Value;
use std::collections::BTreeMap;
use time::{Date, Duration, OffsetDateTime, format_description::well_known::Rfc3339};

#[derive(Clone, Debug)]
pub(super) struct UsageWindow {
    pub(super) start: String,
    pub(super) end: String,
    pub(super) days: u64,
    pub(super) timezone_offset_minutes: i64,
    pub(super) timezone_transitions: Vec<TimezoneTransition>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(super) struct TimezoneTransition {
    at_epoch_seconds: i64,
    offset_minutes: i64,
}

impl UsageWindow {
    pub(super) fn from_params(params: &Value) -> Self {
        let days = params
            .get("historyDays")
            .and_then(number_value)
            .unwrap_or(DEFAULT_USAGE_WINDOW_DAYS)
            .clamp(1, 365);
        let timezone_offset_minutes = signed_param(params, "timezoneOffsetMinutes")
            .unwrap_or(0)
            .clamp(-24 * 60, 24 * 60);
        let timezone_transitions = timezone_transitions_param(params);
        let now_utc = text_param(params, &["now"])
            .and_then(|value| OffsetDateTime::parse(&value, &Rfc3339).ok())
            .unwrap_or_else(OffsetDateTime::now_utc);
        let current_offset = timezone_offset_at(
            now_utc.unix_timestamp(),
            timezone_offset_minutes,
            &timezone_transitions,
        );
        let end_date = (now_utc + Duration::minutes(current_offset)).date();
        let start_date = end_date - Duration::days(days.saturating_sub(1) as i64);
        Self {
            start: date_key_from_date(start_date),
            end: date_key_from_date(end_date),
            days,
            timezone_offset_minutes,
            timezone_transitions,
        }
    }

    pub(super) fn contains(&self, date: &str) -> bool {
        date >= self.start.as_str() && date <= self.end.as_str()
    }

    pub(super) fn date_key(&self, value: &str) -> Option<String> {
        usage_date_key(value, self)
    }

    pub(super) fn cache_timezone_key(&self) -> String {
        let transitions = self
            .timezone_transitions
            .iter()
            .map(|transition| {
                format!(
                    "{}:{}",
                    transition.at_epoch_seconds, transition.offset_minutes
                )
            })
            .collect::<Vec<_>>()
            .join(",");
        format!("{}|{transitions}", self.timezone_offset_minutes)
    }
}

fn timezone_transitions_param(params: &Value) -> Vec<TimezoneTransition> {
    let Some(raw) = params
        .get("timezoneTransitions")
        .or_else(|| params.get("timezoneTransitionsJson"))
    else {
        return Vec::new();
    };
    let parsed = raw
        .as_str()
        .and_then(|value| serde_json::from_str::<Value>(value).ok())
        .unwrap_or_else(|| raw.clone());
    let Some(items) = parsed.as_array() else {
        return Vec::new();
    };
    let mut transitions = BTreeMap::<i64, i64>::new();
    for item in items.iter().take(64) {
        let Some(at_epoch_seconds) =
            signed_number_field(item, &["atEpochSeconds", "at_epoch_seconds", "at"])
        else {
            continue;
        };
        let Some(offset_minutes) =
            signed_number_field(item, &["offsetMinutes", "offset_minutes", "offset"])
        else {
            continue;
        };
        if !(-24 * 60..=24 * 60).contains(&offset_minutes) {
            continue;
        }
        transitions.insert(at_epoch_seconds, offset_minutes);
    }
    transitions
        .into_iter()
        .map(|(at_epoch_seconds, offset_minutes)| TimezoneTransition {
            at_epoch_seconds,
            offset_minutes,
        })
        .collect()
}

fn timezone_offset_at(
    epoch_seconds: i64,
    fallback_offset_minutes: i64,
    transitions: &[TimezoneTransition],
) -> i64 {
    let index =
        transitions.partition_point(|transition| transition.at_epoch_seconds <= epoch_seconds);
    index
        .checked_sub(1)
        .and_then(|index| transitions.get(index))
        .map(|transition| transition.offset_minutes)
        .unwrap_or(fallback_offset_minutes)
}

fn signed_param(params: &Value, key: &str) -> Option<i64> {
    let value = params.get(key)?;
    value
        .as_i64()
        .or_else(|| value.as_str()?.trim().parse::<i64>().ok())
}

fn signed_number_field(value: &Value, keys: &[&str]) -> Option<i64> {
    keys.iter().find_map(|key| {
        let value = value.get(*key)?;
        value
            .as_i64()
            .or_else(|| value.as_u64().and_then(|value| i64::try_from(value).ok()))
            .or_else(|| value.as_str()?.trim().parse::<i64>().ok())
    })
}

fn usage_date_key(value: &str, window: &UsageWindow) -> Option<String> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        return None;
    }
    if trimmed.len() == 10
        && trimmed.as_bytes().get(4) == Some(&b'-')
        && trimmed.as_bytes().get(7) == Some(&b'-')
    {
        return Some(trimmed.to_owned());
    }
    if let Ok(timestamp) = OffsetDateTime::parse(trimmed, &Rfc3339) {
        let offset = timezone_offset_at(
            timestamp.unix_timestamp(),
            window.timezone_offset_minutes,
            &window.timezone_transitions,
        );
        return Some(date_key_from_date(
            (timestamp + Duration::minutes(offset)).date(),
        ));
    }
    trimmed
        .parse::<i64>()
        .ok()
        .and_then(|value| epoch_seconds_to_date_key(value, window))
}

fn epoch_seconds_to_date_key(value: i64, window: &UsageWindow) -> Option<String> {
    if value <= 0 {
        return None;
    }
    let absolute = (value as i128).abs();
    let seconds = if absolute >= 100_000_000_000_000_000 {
        value / 1_000_000_000
    } else if absolute >= 100_000_000_000_000 {
        value / 1_000_000
    } else if absolute >= 100_000_000_000 {
        value / 1_000
    } else {
        value
    };
    let offset = timezone_offset_at(
        seconds,
        window.timezone_offset_minutes,
        &window.timezone_transitions,
    );
    OffsetDateTime::from_unix_timestamp(seconds)
        .ok()
        .map(|time| date_key_from_date((time + Duration::minutes(offset)).date()))
}

fn date_key_from_date(date: Date) -> String {
    format!(
        "{:04}-{:02}-{:02}",
        date.year(),
        u8::from(date.month()),
        date.day()
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn default_window_is_thirty_local_calendar_days() {
        let window = UsageWindow::from_params(&json!({
            "now": "2026-07-15T12:00:00Z"
        }));
        assert_eq!(window.days, 30);
        assert_eq!(window.start, "2026-06-16");
        assert_eq!(window.end, "2026-07-15");
    }

    #[test]
    fn custom_window_and_timezone_transition_are_applied_once() {
        let window = UsageWindow::from_params(&json!({
            "now": "2026-07-15T12:00:00Z",
            "historyDays": "7",
            "timezoneOffsetMinutes": -60,
            "timezoneTransitions": [
                {"atEpochSeconds": 0, "offsetMinutes": 120}
            ]
        }));
        assert_eq!(window.days, 7);
        assert_eq!(window.start, "2026-07-09");
        assert_eq!(window.end, "2026-07-15");
        assert_eq!(
            window.date_key("2026-07-01T23:30:00Z").as_deref(),
            Some("2026-07-02")
        );
        assert!(window.cache_timezone_key().contains("0:120"));
    }

    #[test]
    fn requested_window_is_bounded_to_one_through_three_hundred_sixty_five_days() {
        let minimum = UsageWindow::from_params(&json!({
            "now": "2026-07-15T12:00:00Z",
            "historyDays": 0
        }));
        let maximum = UsageWindow::from_params(&json!({
            "now": "2026-07-15T12:00:00Z",
            "historyDays": 999
        }));

        assert_eq!(minimum.days, 1);
        assert_eq!(minimum.start, minimum.end);
        assert_eq!(maximum.days, 365);
        assert_eq!(maximum.start, "2025-07-16");
        assert_eq!(maximum.end, "2026-07-15");
    }
}
