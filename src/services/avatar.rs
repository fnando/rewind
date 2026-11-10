//! User avatars: any common image, auto-oriented, cropped to a 250px square
//! and stored as JPEG in the data dir.

use std::io::Cursor;

use anyhow::{Context, Result, bail};
use image::codecs::jpeg::JpegEncoder;
use image::imageops::FilterType;
use image::{DynamicImage, ImageDecoder, ImageReader};

use crate::config::Config;

pub const SIZE: u32 = 250;

/// Processes and stores an uploaded image as the user's avatar.
pub fn write(config: &Config, user_id: i64, bytes: &[u8]) -> Result<()> {
    if bytes.is_empty() {
        bail!("No file uploaded");
    }
    let mut decoder = ImageReader::new(Cursor::new(bytes))
        .with_guessed_format()?
        .into_decoder()
        .context("Could not process image")?;
    let orientation = decoder.orientation().ok();
    let mut image = DynamicImage::from_decoder(decoder).context("Could not process image")?;
    if image.width() == 0 || image.height() == 0 {
        bail!("Invalid image");
    }
    if let Some(orientation) = orientation {
        image.apply_orientation(orientation);
    }
    let square = image
        .resize_to_fill(SIZE, SIZE, FilterType::Lanczos3)
        .to_rgb8();
    let mut out = Vec::new();
    JpegEncoder::new_with_quality(&mut out, 85).encode_image(&square)?;
    std::fs::create_dir_all(config.avatars_dir())?;
    std::fs::write(config.avatar_path(user_id), out)?;
    Ok(())
}

pub fn delete(config: &Config, user_id: i64) {
    let _ = std::fs::remove_file(config.avatar_path(user_id));
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn crops_to_a_square_jpeg() {
        let dir = tempfile::tempdir().unwrap();
        let config = Config {
            data_dir: dir.path().into(),
            ..Config::default()
        };
        let mut png = Vec::new();
        DynamicImage::new_rgb8(400, 200)
            .write_to(&mut Cursor::new(&mut png), image::ImageFormat::Png)
            .unwrap();
        write(&config, 1, &png).unwrap();
        let stored = image::open(config.avatar_path(1)).unwrap();
        assert_eq!((stored.width(), stored.height()), (SIZE, SIZE));
        assert!(write(&config, 1, b"not an image").is_err());
        delete(&config, 1);
        assert!(!config.avatar_path(1).exists());
    }
}
