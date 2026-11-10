//! Artist photos from fanart.tv, looked up by MusicBrainz artist id.

use serde_json::Value;

use super::http;
use crate::config::Config;

#[derive(Debug, Clone)]
pub struct Fanart {
    api_key: Option<String>,
    base_url: String,
}

impl Fanart {
    #[must_use]
    pub fn new(config: &Config) -> Self {
        Self {
            api_key: config.fanart_api_key.clone(),
            base_url: config.fanart_url.clone(),
        }
    }

    /// An image URL, or `None`. Never fails: a missing key, a keyless
    /// artist, a 404 or a transport error all mean "no photo", so ingestion
    /// is never blocked on artwork.
    #[must_use]
    pub fn artist_image(&self, mbid: Option<&str>) -> Option<String> {
        let key = self.api_key.as_deref()?;
        let mbid = mbid.filter(|m| !m.is_empty())?;
        let response = http::get(format!("{}/music/{mbid}", self.base_url))
            .query("api_key", &key)
            .send()
            .ok()?;
        if !response.ok() {
            return None;
        }
        let data: Value = response.json().ok()?;
        ["artistthumb", "artistbackground"]
            .iter()
            .filter_map(|key| data.get(key).and_then(Value::as_array))
            .flatten()
            .find_map(|image| image.get("url").and_then(Value::as_str).map(String::from))
    }
}
