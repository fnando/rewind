//! Fetches a remote cover image's bytes. Only well-known image hosts (over
//! https) and the connected Jellyfin servers are allowed; redirects are
//! followed (Cover Art Archive redirects to archive.org).

use std::time::Duration;

use super::http;

const ALLOWED_HOSTS: &[&str] = &["image.tmdb.org", "coverartarchive.org", "assets.fanart.tv"];
const MAX_BYTES: usize = 5 * 1024 * 1024;

/// Whether `url` may be fetched: an https image CDN, or one of the
/// connected servers' hosts (often plain http on a LAN).
#[must_use]
pub fn allowed(url: &str, source_hosts: &[String]) -> bool {
    let Ok(parsed) = url::Url::parse(url) else {
        return false;
    };
    let Some(host) = parsed.host_str() else {
        return false;
    };
    match parsed.scheme() {
        "https" if ALLOWED_HOSTS.contains(&host) => true,
        "http" | "https" => source_hosts.iter().any(|h| h == host),
        _ => false,
    }
}

/// The image bytes, or `None` on any failure.
#[must_use]
pub fn fetch(url: &str, source_hosts: &[String]) -> Option<Vec<u8>> {
    if !allowed(url, source_hosts) {
        return None;
    }
    let response = http::get(url)
        .header("Accept", "image/*")
        .timeout(Duration::from_secs(8))
        .send()
        .inspect_err(|e| tracing::info!("[images] fetch failed for {url}: {e}"))
        .ok()?;
    if !response.ok() || response.body.is_empty() || response.body.len() > MAX_BYTES {
        return None;
    }
    Some(response.body)
}

/// The hosts of every connected server's URL.
#[must_use]
pub fn source_hosts(urls: &[String]) -> Vec<String> {
    urls.iter()
        .filter_map(|u| url::Url::parse(u).ok()?.host_str().map(String::from))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn allows_cdns_over_https_and_connected_servers() {
        let hosts = vec!["jellyfin".to_string()];
        assert!(allowed("https://image.tmdb.org/t/p/w342/x.jpg", &hosts));
        assert!(!allowed("http://image.tmdb.org/t/p/w342/x.jpg", &hosts));
        assert!(allowed(
            "http://jellyfin:8096/Items/1/Images/Primary",
            &hosts
        ));
        assert!(!allowed("https://evil.test/x.jpg", &hosts));
        assert!(!allowed("file:///etc/passwd", &hosts));
    }
}
