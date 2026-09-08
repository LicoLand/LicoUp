//! M1 cognition and context leaves plus the M2 host that attaches them.

pub mod cognition;
pub mod context;
pub mod execution;
pub mod host;
pub mod live;

pub use cognition::{UnavailableInterpretationService, interpretation_port};
pub use context::{UnavailableContextCompositionService, context_composition_port};
pub use host::{
    ChildControlDisposition, ChildWorkFault, ContinuityHost, set_child_assembly_recheck_failures,
    set_child_work_fault,
};
