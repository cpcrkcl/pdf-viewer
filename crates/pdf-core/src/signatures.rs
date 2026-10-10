//! Local libraries of visual signatures and custom stamps.
//!
//! Images live in Application Support next to a versioned JSON index. They
//! only leave the Mac inside PDFs the user exports.

use std::path::PathBuf;

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::annotations::{MAXIMUM_IMAGE_PIXELS, validated_image};
use crate::error::{CoreError, CoreResult};
use crate::persistence::write_atomically;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StoredSignature {
    pub id: Uuid,
    pub display_name: String,
    pub file_name: String,
    pub aspect_ratio: f64,
    pub created_at: DateTime<Utc>,
}

pub struct SignatureLibrary {
    directory: PathBuf,
    signatures: Vec<StoredSignature>,
    default_name: &'static str,
}

impl SignatureLibrary {
    /// `folder` is "Signatures" or "Stamps" under the support directory.
    pub fn new(directory: PathBuf, default_name: &'static str) -> Self {
        let mut library = Self {
            directory,
            signatures: Vec::new(),
            default_name,
        };
        library.load();
        library
    }

    pub fn signatures(&self) -> &[StoredSignature] {
        &self.signatures
    }

    fn index_path(&self) -> PathBuf {
        self.directory.join("signatures.v1.json")
    }

    fn load(&mut self) {
        let Ok(data) = std::fs::read(self.index_path()) else { return };
        let Ok(decoded) = serde_json::from_slice::<Vec<StoredSignature>>(&data) else { return };
        let mut seen = std::collections::HashSet::new();
        let mut signatures: Vec<StoredSignature> = decoded
            .into_iter()
            .filter(|signature| {
                is_safe_file_name(&signature.file_name, signature.id)
                    && signature.aspect_ratio.is_finite()
                    && signature.aspect_ratio > 0.0
                    && std::fs::read(self.directory.join(&signature.file_name))
                        .ok()
                        .is_some_and(|data| validated_image(&data).is_ok())
                    && seen.insert(signature.id)
            })
            .map(|mut signature| {
                signature.display_name = self.sanitized_name(&signature.display_name);
                signature
            })
            .collect();
        signatures.sort_by_key(|signature| signature.created_at);
        self.signatures = signatures;
    }

    fn sanitized_name(&self, name: &str) -> String {
        let trimmed = name.trim();
        let name = if trimmed.is_empty() { self.default_name } else { trimmed };
        name.chars().take(80).collect()
    }

    pub fn import_image(&mut self, data: &[u8], display_name: &str) -> CoreResult<StoredSignature> {
        let (width, height) = validated_image(data)?;
        let extension = match image::guess_format(data) {
            Ok(image::ImageFormat::Jpeg) => "jpg",
            _ => "png",
        };
        std::fs::create_dir_all(&self.directory)?;
        let id = Uuid::new_v4();
        let file_name = format!("{}.{extension}", id.as_hyphenated().to_string().to_lowercase());
        let path = self.directory.join(&file_name);
        write_atomically(&path, data)?;
        let stored = StoredSignature {
            id,
            display_name: self.sanitized_name(display_name),
            file_name,
            aspect_ratio: f64::from(width) / f64::from(height),
            created_at: Utc::now(),
        };
        self.signatures.push(stored.clone());
        if let Err(error) = self.persist() {
            self.signatures.retain(|signature| signature.id != id);
            let _ = std::fs::remove_file(&path);
            return Err(error);
        }
        Ok(stored)
    }

    /// Renders strokes (canvas points, y down) as black ink on transparency.
    pub fn create_from_drawing(
        &mut self,
        strokes: &[Vec<(f32, f32)>],
        canvas: (f32, f32),
        display_name: &str,
    ) -> CoreResult<StoredSignature> {
        let drawable: Vec<&Vec<(f32, f32)>> = strokes.iter().filter(|stroke| stroke.len() >= 2).collect();
        let valid_canvas = canvas.0.is_finite()
            && canvas.1.is_finite()
            && canvas.0 > 0.0
            && canvas.1 > 0.0
            && (canvas.0 * canvas.1) as u64 <= MAXIMUM_IMAGE_PIXELS;
        if drawable.is_empty()
            || !valid_canvas
            || drawable.iter().any(|stroke| stroke.iter().any(|(x, y)| !x.is_finite() || !y.is_finite()))
        {
            return Err(CoreError::EmptyDrawing);
        }
        // Render at 2x for crisp edges.
        let scale = 2.0;
        let (width, height) = ((canvas.0 * scale).ceil() as u32, (canvas.1 * scale).ceil() as u32);
        let mut image = image::RgbaImage::new(width, height);
        let radius = 1.5 * scale;
        for stroke in drawable {
            for segment in stroke.windows(2) {
                let (a, b) = ((segment[0].0 * scale, segment[0].1 * scale), (segment[1].0 * scale, segment[1].1 * scale));
                let steps = ((b.0 - a.0).hypot(b.1 - a.1) / 0.75).ceil().max(1.0) as usize;
                for step in 0..=steps {
                    let t = step as f32 / steps as f32;
                    stamp_disc(&mut image, a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t, radius);
                }
            }
        }
        let mut png = Vec::new();
        image::DynamicImage::ImageRgba8(image)
            .write_to(&mut std::io::Cursor::new(&mut png), image::ImageFormat::Png)
            .map_err(|_| CoreError::Io("PDFViewer could not save that signature image locally.".into()))?;
        self.import_image(&png, display_name)
    }

    pub fn image_data(&self, id: Uuid) -> CoreResult<Vec<u8>> {
        let signature = self.signatures.iter().find(|signature| signature.id == id).ok_or(CoreError::MissingSignature)?;
        let data = std::fs::read(self.directory.join(&signature.file_name)).map_err(|_| CoreError::MissingSignature)?;
        validated_image(&data).map_err(|_| CoreError::MissingSignature)?;
        Ok(data)
    }

    pub fn delete(&mut self, id: Uuid) -> CoreResult<()> {
        let index = self.signatures.iter().position(|signature| signature.id == id).ok_or(CoreError::MissingSignature)?;
        let removed = self.signatures.remove(index);
        if let Err(error) = self.persist() {
            self.signatures.insert(index, removed);
            return Err(error);
        }
        let _ = std::fs::remove_file(self.directory.join(&removed.file_name));
        Ok(())
    }

    fn persist(&self) -> CoreResult<()> {
        std::fs::create_dir_all(&self.directory)?;
        let data = serde_json::to_vec(&self.signatures).map_err(|error| CoreError::Io(error.to_string()))?;
        write_atomically(&self.index_path(), &data)
    }
}

fn stamp_disc(image: &mut image::RgbaImage, cx: f32, cy: f32, radius: f32) {
    let (width, height) = (image.width() as i64, image.height() as i64);
    let reach = radius.ceil() as i64 + 1;
    for y in (cy as i64 - reach).max(0)..(cy as i64 + reach + 1).min(height) {
        for x in (cx as i64 - reach).max(0)..(cx as i64 + reach + 1).min(width) {
            let distance = ((x as f32 + 0.5 - cx).powi(2) + (y as f32 + 0.5 - cy).powi(2)).sqrt();
            let coverage = (radius + 0.5 - distance).clamp(0.0, 1.0);
            if coverage > 0.0 {
                let pixel = image.get_pixel_mut(x as u32, y as u32);
                let alpha = (pixel[3] as f32).max(coverage * 255.0) as u8;
                *pixel = image::Rgba([0, 0, 0, alpha]);
            }
        }
    }
}

fn is_safe_file_name(file_name: &str, id: Uuid) -> bool {
    if file_name.contains(['/', '\\', ':']) || file_name.starts_with('.') {
        return false;
    }
    let Some((stem, extension)) = file_name.rsplit_once('.') else { return false };
    Uuid::parse_str(stem).ok() == Some(id) && matches!(extension.to_ascii_lowercase().as_str(), "png" | "jpg" | "jpeg")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn import_draw_reload_and_delete() {
        let dir = tempfile::tempdir().unwrap();
        let mut library = SignatureLibrary::new(dir.path().join("Signatures"), "Visual Signature");
        let png = crate::testing::signature_png(90, 30);
        let imported = library.import_image(&png, "  ").unwrap();
        assert_eq!(imported.display_name, "Visual Signature");
        assert!((imported.aspect_ratio - 3.0).abs() < 1e-9);
        assert_eq!(library.image_data(imported.id).unwrap(), png);
        assert!(library.import_image(b"not an image", "Bad").is_err());

        let drawn = library
            .create_from_drawing(&[vec![(10.0, 10.0), (80.0, 40.0)], vec![(5.0, 5.0)]], (100.0, 50.0), "Drawn")
            .unwrap();
        assert!(library.image_data(drawn.id).unwrap().starts_with(b"\x89PNG"));
        assert_eq!(library.create_from_drawing(&[vec![(1.0, 1.0)]], (10.0, 10.0), "x"), Err(CoreError::EmptyDrawing));

        let reloaded = SignatureLibrary::new(dir.path().join("Signatures"), "Visual Signature");
        assert_eq!(reloaded.signatures().len(), 2);

        library.delete(imported.id).unwrap();
        assert_eq!(library.signatures().len(), 1);
        assert!(library.image_data(imported.id).is_err());
        // A tampered index entry pointing outside the library is ignored.
        let mut tampered = library.signatures().to_vec();
        tampered[0].file_name = "../escape.png".into();
        std::fs::write(dir.path().join("Signatures/signatures.v1.json"), serde_json::to_vec(&tampered).unwrap()).unwrap();
        assert!(SignatureLibrary::new(dir.path().join("Signatures"), "Visual Signature").signatures().is_empty());
    }
}
