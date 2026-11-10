//! Plain structs for each table plus the queries that read and write them.
//! Every function takes a `&Connection`, so callers choose the connection
//! (pooled in the web server, owned in the CLI and tests).

pub mod error_log;
pub mod item;
pub mod play;
pub mod source;
pub mod user;
pub mod user_item;

pub use error_log::ErrorLog;
pub use item::Item;
pub use play::Play;
pub use source::{Source, SourceError};
pub use user::User;
pub use user_item::UserItem;

/// A validation failure, with one message per problem.
#[derive(Debug, thiserror::Error)]
#[error("{}", .0.join(", "))]
pub struct Invalid(pub Vec<String>);
