//! The client's half of the Kilo Code driver seam.
//!
//! This suite states what the client still owns: the driver identity the shared
//! result vocabulary is stamped with, the launch shape, the engine functions the
//! package's ports are answered with, and the translation of a package failure
//! onto the client's failure type. The Agent's own half — the request shape, the
//! stream classification, the projection, the probe decisions and the parser —
//! is stated by the package's own suite, because it is the package that owns it.

mod composition;
mod execution;
mod host;
mod probe;
