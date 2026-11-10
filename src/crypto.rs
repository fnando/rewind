//! Encryption for the Jellyfin access tokens stored in `sources`.
//!
//! XChaCha20-Poly1305 with a random 24-byte nonce, stored as
//! base64(nonce ‖ ciphertext). The key is `Config::resolved_secret_key`.

use anyhow::{Result, anyhow};
use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use chacha20poly1305::aead::{Aead, KeyInit};
use chacha20poly1305::{XChaCha20Poly1305, XNonce};

const NONCE_LEN: usize = 24;

#[must_use]
pub fn encode(bytes: &[u8]) -> String {
    STANDARD.encode(bytes)
}

/// # Errors
/// When `value` isn't valid base64.
pub fn decode(value: &str) -> Result<Vec<u8>> {
    Ok(STANDARD.decode(value.trim())?)
}

/// # Errors
/// Only if the cipher itself fails, which it doesn't for valid keys.
pub fn encrypt(key: &[u8; 32], plaintext: &str) -> Result<String> {
    let cipher = XChaCha20Poly1305::new(key.into());
    let nonce_bytes: [u8; NONCE_LEN] = rand::random();
    let nonce = XNonce::from(nonce_bytes);
    let ciphertext = cipher
        .encrypt(&nonce, plaintext.as_bytes())
        .map_err(|_| anyhow!("encryption failed"))?;
    let mut out = nonce_bytes.to_vec();
    out.extend_from_slice(&ciphertext);
    Ok(encode(&out))
}

/// # Errors
/// When the value is malformed or was encrypted with another key.
pub fn decrypt(key: &[u8; 32], value: &str) -> Result<String> {
    let bytes = decode(value)?;
    if bytes.len() <= NONCE_LEN {
        return Err(anyhow!("encrypted value is too short"));
    }
    let (nonce, ciphertext) = bytes.split_at(NONCE_LEN);
    let nonce: [u8; NONCE_LEN] = nonce.try_into()?;
    let cipher = XChaCha20Poly1305::new(key.into());
    let plain = cipher
        .decrypt(&XNonce::from(nonce), ciphertext)
        .map_err(|_| anyhow!("could not decrypt; was REWIND_SECRET_KEY changed?"))?;
    Ok(String::from_utf8(plain)?)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trips() {
        let key = [7u8; 32];
        let sealed = encrypt(&key, "token-123").unwrap();
        assert_ne!(sealed, "token-123");
        assert_eq!(decrypt(&key, &sealed).unwrap(), "token-123");
    }

    #[test]
    fn uses_a_fresh_nonce_each_time() {
        let key = [7u8; 32];
        assert_ne!(encrypt(&key, "x").unwrap(), encrypt(&key, "x").unwrap());
    }

    #[test]
    fn rejects_another_key() {
        let sealed = encrypt(&[1u8; 32], "token").unwrap();
        assert!(decrypt(&[2u8; 32], &sealed).is_err());
    }
}
