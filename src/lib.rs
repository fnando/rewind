//! Rewind: a personal watch and listening history fed by the Jellyfin
//! Rewind plugin.

// An application crate: every fallible function returns `anyhow::Result`,
// and the panics are invariants (a row that was just written).
#![allow(clippy::missing_errors_doc, clippy::missing_panics_doc)]

pub mod cli;
pub mod config;
pub mod crypto;
pub mod db;
pub mod models;
pub mod server;
pub mod services;
pub mod time;
pub mod web;
