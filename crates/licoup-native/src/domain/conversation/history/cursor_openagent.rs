//! Stable composition root for bounded Cursor and OpenAgent SQLite history parsing.

pub(super) mod codec;
mod composition;
mod cursor;
mod cursor_cli;
mod cursor_projection;
mod fallback;
mod openagent;

pub(crate) use composition::parse_sqlite_sessions;

#[cfg(test)]
mod tests;
