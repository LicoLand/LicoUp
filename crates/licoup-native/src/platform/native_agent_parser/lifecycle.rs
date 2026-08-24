use serde_json::{Value, json};

#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub(in crate::platform) enum LifecycleStage {
    Submitted,
    Accepted,
    Processing,
    Responding,
    Completed,
}

impl LifecycleStage {
    pub(in crate::platform) const ALL: [Self; 5] = [
        Self::Submitted,
        Self::Accepted,
        Self::Processing,
        Self::Responding,
        Self::Completed,
    ];

    pub(in crate::platform) const fn wire_name(self) -> &'static str {
        match self {
            Self::Submitted => "submitted",
            Self::Accepted => "accepted",
            Self::Processing => "processing",
            Self::Responding => "responding",
            Self::Completed => "completed",
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(in crate::platform) enum Transition {
    Lifecycle(LifecycleStage),
    Text {
        unit_id: String,
        text: String,
    },
    #[allow(dead_code)]
    Control {
        method: String,
        summary: String,
    },
    Failed {
        code: String,
        stage: String,
        message: String,
    },
}

impl Transition {
    pub(in crate::platform) fn to_json(&self) -> Value {
        match self {
            Self::Lifecycle(stage) => json!({
                "kind": "lifecycle",
                "stage": stage.wire_name(),
            }),
            Self::Text { unit_id, text } => json!({
                "kind": "text",
                "unitId": unit_id,
                "text": text,
            }),
            Self::Control { method, summary } => json!({
                "kind": "control",
                "method": method,
                "summary": summary,
            }),
            Self::Failed {
                code,
                stage,
                message,
            } => json!({
                "kind": "failed",
                "code": code,
                "stage": stage,
                "message": message,
            }),
        }
    }
}

/// Arrival-ordered lifecycle and terminal reduction. Stages are prefix closed;
/// the first exact native failure is write-once.
#[derive(Default)]
pub(in crate::platform) struct TransitionReducer {
    highest: Option<LifecycleStage>,
    failure: Option<Transition>,
}

impl TransitionReducer {
    pub(in crate::platform) fn advance(&mut self, stage: LifecycleStage) -> Vec<Transition> {
        if self.failure.is_some() || self.highest.is_some_and(|current| current >= stage) {
            return Vec::new();
        }
        let start = self.highest.map_or(0, |current| current as usize + 1);
        self.highest = Some(stage);
        LifecycleStage::ALL[start..=stage as usize]
            .iter()
            .copied()
            .map(Transition::Lifecycle)
            .collect()
    }

    pub(in crate::platform) fn fail(
        &mut self,
        code: impl Into<String>,
        stage: impl Into<String>,
        message: impl Into<String>,
    ) -> Option<Transition> {
        if self.failure.is_some() || self.highest == Some(LifecycleStage::Completed) {
            return None;
        }
        let failure = Transition::Failed {
            code: code.into(),
            stage: stage.into(),
            message: message.into(),
        };
        self.failure = Some(failure.clone());
        Some(failure)
    }
}
