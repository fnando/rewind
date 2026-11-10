//! A tiny blocking HTTP layer over `ureq`: timeouts, no status-as-error, and
//! a plain response struct the service clients can inspect.

use std::time::Duration;

use anyhow::{Result, anyhow};
use serde::de::DeserializeOwned;
use serde_json::Value;

pub const USER_AGENT: &str = concat!("rewind/", env!("CARGO_PKG_VERSION"));
const MAX_BODY: u64 = 20 * 1024 * 1024;

#[derive(Debug, Clone)]
pub struct Response {
    pub status: u16,
    pub body: Vec<u8>,
}

impl Response {
    #[must_use]
    pub fn ok(&self) -> bool {
        (200..300).contains(&self.status)
    }

    #[must_use]
    pub fn text(&self) -> String {
        String::from_utf8_lossy(&self.body).into_owned()
    }

    /// The first `n` characters of the body, for error messages.
    #[must_use]
    pub fn excerpt(&self, n: usize) -> String {
        self.text().trim().chars().take(n).collect()
    }

    pub fn json<T: DeserializeOwned>(&self) -> Result<T> {
        Ok(serde_json::from_slice(&self.body)?)
    }
}

/// A request in the making.
pub struct Request {
    method: &'static str,
    url: String,
    query: Vec<(String, String)>,
    headers: Vec<(String, String)>,
    json: Option<Value>,
    timeout: Duration,
}

#[must_use]
pub fn get(url: impl Into<String>) -> Request {
    Request::new("GET", url.into())
}

#[must_use]
pub fn post(url: impl Into<String>) -> Request {
    Request::new("POST", url.into())
}

impl Request {
    fn new(method: &'static str, url: String) -> Self {
        Self {
            method,
            url,
            query: Vec::new(),
            headers: vec![("Accept".into(), "application/json".into())],
            json: None,
            timeout: Duration::from_secs(8),
        }
    }

    #[must_use]
    pub fn query<V: std::fmt::Display + ?Sized>(mut self, key: &str, value: &V) -> Self {
        self.query.push((key.into(), value.to_string()));
        self
    }

    #[must_use]
    pub fn header(mut self, key: &str, value: impl Into<String>) -> Self {
        self.headers.retain(|(k, _)| !k.eq_ignore_ascii_case(key));
        self.headers.push((key.into(), value.into()));
        self
    }

    #[must_use]
    pub fn json(mut self, body: Value) -> Self {
        self.json = Some(body);
        self
    }

    #[must_use]
    pub fn timeout(mut self, timeout: Duration) -> Self {
        self.timeout = timeout;
        self
    }

    /// Sends the request. Any HTTP status is returned as a response; only
    /// transport failures (DNS, connect, timeout) are errors.
    pub fn send(self) -> Result<Response> {
        let agent: ureq::Agent = ureq::Agent::config_builder()
            .timeout_global(Some(self.timeout))
            .http_status_as_error(false)
            .user_agent(USER_AGENT)
            .build()
            .into();
        let mut response = if self.method == "POST" {
            let mut request = agent.post(&self.url);
            for (k, v) in &self.query {
                request = request.query(k, v);
            }
            for (k, v) in &self.headers {
                request = request.header(k, v);
            }
            match self.json {
                Some(body) => request.send_json(body),
                None => request.send_empty(),
            }
        } else {
            let mut request = agent.get(&self.url);
            for (k, v) in &self.query {
                request = request.query(k, v);
            }
            for (k, v) in &self.headers {
                request = request.header(k, v);
            }
            request.call()
        }
        .map_err(|e| anyhow!("{e}"))?;
        let status = response.status().as_u16();
        let body = response
            .body_mut()
            .with_config()
            .limit(MAX_BODY)
            .read_to_vec()
            .map_err(|e| anyhow!("{e}"))?;
        Ok(Response { status, body })
    }
}
