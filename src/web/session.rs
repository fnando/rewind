//! The session: a signed cookie holding the signed-in user, the CSRF token and
//! one-shot flash messages.

use std::sync::{Arc, Mutex};

use serde::{Deserialize, Serialize};

pub const COOKIE: &str = "rewind.session";
pub const MAX_AGE_DAYS: i64 = 30;

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionData {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub user_id: Option<i64>,
    #[serde(default)]
    pub csrf: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub notice: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

/// The request's session, shared between the middleware and the handler.
#[derive(Debug, Clone, Default)]
pub struct Session(pub Arc<Mutex<SessionData>>);

impl Session {
    #[must_use]
    pub fn new(data: SessionData) -> Self {
        Self(Arc::new(Mutex::new(data)))
    }

    pub fn with<T>(&self, f: impl FnOnce(&mut SessionData) -> T) -> T {
        f(&mut self.0.lock().expect("session lock"))
    }

    #[must_use]
    pub fn snapshot(&self) -> SessionData {
        self.with(|data| data.clone())
    }

    pub fn notice(&self, message: impl Into<String>) {
        let message = message.into();
        self.with(|data| data.notice = Some(message));
    }

    pub fn error(&self, message: impl Into<String>) {
        let message = message.into();
        self.with(|data| data.error = Some(message));
    }

    #[must_use]
    pub fn csrf(&self) -> String {
        self.with(|data| data.csrf.clone())
    }

    /// Signs in: a fresh session (new CSRF token) for the user.
    pub fn sign_in(&self, user_id: i64) {
        self.with(|data| {
            *data = SessionData {
                user_id: Some(user_id),
                csrf: new_token(),
                ..SessionData::default()
            };
        });
    }

    pub fn clear(&self) {
        self.with(|data| {
            *data = SessionData {
                csrf: new_token(),
                ..SessionData::default()
            };
        });
    }
}

#[must_use]
pub fn new_token() -> String {
    hex::encode(rand::random::<[u8; 32]>())
}
