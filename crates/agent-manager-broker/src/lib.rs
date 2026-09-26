//! Contract-first broker core for Agent Manager.
//!
//! M1 adds an embedded stdio broker while retaining the contract-first provider
//! boundaries established in M0.

pub mod codex;
pub mod durable;
pub mod embedded;
mod framing;
mod human;
mod projection;
pub mod protocol;
mod registry;
pub mod replay;
mod runtime;
mod status;
pub mod transcript;
pub mod worker;
pub mod workspace;

pub const BROKER_VERSION: &str = env!("CARGO_PKG_VERSION");
