//! Identity of the bundled LicoUp usage Skill that one MCP registration delivers.
//!
//! A single approval publishes this Skill to the provider's user Skill Hub root
//! and to the shared `.agents/skills` surface, so the crate that owns the
//! registration owns the Skill's identity: the stable name it is published under
//! and the exact source published under it. The layers above read that identity
//! downward — the conversation host names it when it admits, ranks and projects
//! profile Skills, and the persistent dispatch guidance embeds the source
//! verbatim — instead of holding a second copy of either.

/// Published directory name of the bundled Skill, and the Skill reference the
/// Assistant Profile carries for it.
pub const LICOUP_GUIDE_SKILL_ID: &str = "licoup-guide";

/// The published Skill source, embedded so one approval can deliver it without
/// reading the product tree at runtime.
pub const LICOUP_GUIDE_SKILL_SOURCE: &str = include_str!("../resources/licoup-guide/SKILL.md");
