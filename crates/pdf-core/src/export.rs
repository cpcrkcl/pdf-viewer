//! Exporting the working copy.
//!
//! The output is staged in a temporary file, reopened and compared against a
//! semantic snapshot of the working copy (pages, rotations, boxes, text,
//! annotations, form values), then atomically placed at the destination and
//! verified once more. The source PDF can never be the destination.

use std::path::{Path, PathBuf};

use lopdf::{Document as LoDocument, Object, ObjectId};
use thiserror::Error;

use crate::engine;
use crate::loader::AccessPermissions;
use crate::persistence::write_atomically;
use crate::security;
use crate::structure;

#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum ExportError {
    #[error("The working copy has no pages to export.")]
    EmptyDocument,
    #[error("Choose a destination ending in .pdf.")]
    InvalidDestination,
    #[error("Choose a new output location. PDFViewer never replaces the original PDF.")]
    SourceAndDestinationMatch,
    #[error("PDFViewer could not write a temporary export file.")]
    CouldNotWriteTemporaryFile,
    #[error("PDFViewer could not validate the temporary export file.")]
    CouldNotValidateTemporaryFile,
    #[error("PDFViewer could not finish placing the exported PDF at the chosen location.")]
    CouldNotFinalizeExport,
    #[error("PDFViewer could not reopen the completed export for verification.")]
    CouldNotReopenExport,
    #[error("The active encrypted document no longer has an in-memory session password. Reopen it and try again.")]
    MissingSessionPassword,
    #[error("PDFViewer refused to create an unencrypted copy of this protected PDF.")]
    EncryptedOutputRequired,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, serde::Serialize, serde::Deserialize)]
pub enum Compression {
    #[default]
    Standard,
    ReducedSize,
    Compact,
}

impl Compression {
    pub const ALL: [Self; 3] = [Self::Standard, Self::ReducedSize, Self::Compact];

    pub fn title(self) -> &'static str {
        match self {
            Self::Standard => "Standard",
            Self::ReducedSize => "Reduced Size",
            Self::Compact => "Compact",
        }
    }

    pub fn summary(self) -> &'static str {
        match self {
            Self::Standard => "Keeps the original image quality.",
            Self::ReducedSize => "Re-encodes embedded images as JPEG.",
            Self::Compact => "Re-encodes images as JPEG and downsamples oversized images for screen reading.",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Protection {
    None,
    /// Re-encrypt with the session password as both user and owner password.
    ReuseSessionPassword {
        password: String,
        permissions: AccessPermissions,
    },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ExportResult {
    pub path: PathBuf,
    pub page_count: usize,
    pub file_size: u64,
}

pub fn export(
    working_copy: &[u8],
    source: &Path,
    destination: &Path,
    protection: &Protection,
    compression: Compression,
) -> Result<ExportResult, ExportError> {
    let is_pdf = destination
        .extension()
        .and_then(|extension| extension.to_str())
        .is_some_and(|extension| extension.eq_ignore_ascii_case("pdf"));
    if !is_pdf || destination.file_name().is_none() {
        return Err(ExportError::InvalidDestination);
    }
    if refers_to_same_file(source, destination) {
        return Err(ExportError::SourceAndDestinationMatch);
    }

    let expected = Snapshot::of(working_copy).ok_or(ExportError::CouldNotValidateTemporaryFile)?;
    if expected.pages.is_empty() {
        return Err(ExportError::EmptyDocument);
    }

    let staged = render_output(working_copy, protection, compression)?;
    if !is_valid(&staged, &expected, protection) {
        return Err(ExportError::CouldNotValidateTemporaryFile);
    }
    write_atomically(destination, &staged).map_err(|_| ExportError::CouldNotFinalizeExport)?;
    let written = std::fs::read(destination).map_err(|_| ExportError::CouldNotReopenExport)?;
    if !is_valid(&written, &expected, protection) {
        return Err(ExportError::CouldNotReopenExport);
    }
    Ok(ExportResult {
        path: destination.to_path_buf(),
        page_count: expected.pages.len(),
        file_size: written.len() as u64,
    })
}

fn render_output(
    working_copy: &[u8],
    protection: &Protection,
    compression: Compression,
) -> Result<Vec<u8>, ExportError> {
    let mut document = structure::parse(working_copy).map_err(|_| ExportError::CouldNotWriteTemporaryFile)?;
    match compression {
        Compression::Standard => {}
        Compression::ReducedSize => recompress_images(&mut document, 80, None),
        Compression::Compact => recompress_images(&mut document, 60, Some(1600)),
    }
    document.prune_objects();
    document.compress();
    if let Protection::ReuseSessionPassword { password, permissions } = protection {
        security::encrypt(&mut document, password, password, *permissions)
            .map_err(|_| ExportError::CouldNotWriteTemporaryFile)?;
    }
    structure::serialize(&mut document).map_err(|_| ExportError::CouldNotWriteTemporaryFile)
}

fn is_valid(bytes: &[u8], expected: &Snapshot, protection: &Protection) -> bool {
    let decrypted = match protection {
        Protection::None => {
            if matches!(LoDocument::load_mem(bytes), Ok(document) if document.was_encrypted() || document.is_encrypted()) {
                return false;
            }
            bytes.to_vec()
        }
        Protection::ReuseSessionPassword { password, .. } => {
            if !password.is_empty() {
                let wrong = if password == "pdfviewer-incorrect-password" {
                    "pdfviewer-other-incorrect-password"
                } else {
                    "pdfviewer-incorrect-password"
                };
                if engine::load(bytes.to_vec(), Some(wrong)).is_ok() || engine::load(bytes.to_vec(), None).is_ok() {
                    return false;
                }
            }
            if engine::load(bytes.to_vec(), Some(password)).is_err() {
                return false;
            }
            match engine::load(bytes.to_vec(), Some(password)).and_then(|document| engine::serialize(&document)) {
                Ok(_) => {}
                Err(_) => return false,
            }
            let Ok(mut document) =
                LoDocument::load_mem_with_options(bytes, lopdf::LoadOptions::with_password(password))
            else {
                return false;
            };
            if !(document.is_encrypted() || document.was_encrypted()) {
                return false;
            }
            if document.is_encrypted() && document.decrypt(password).is_err() {
                return false;
            }
            document.trailer.remove(b"Encrypt");
            match structure::serialize(&mut document) {
                Ok(bytes) => bytes,
                Err(_) => return false,
            }
        }
    };
    Snapshot::of(&decrypted).is_some_and(|actual| &actual == expected)
}

fn refers_to_same_file(source: &Path, destination: &Path) -> bool {
    let canonical_source = std::fs::canonicalize(source).unwrap_or_else(|_| source.to_path_buf());
    let canonical_destination = std::fs::canonicalize(destination).unwrap_or_else(|_| {
        destination
            .parent()
            .and_then(|parent| std::fs::canonicalize(parent).ok())
            .map(|parent| parent.join(destination.file_name().unwrap_or_default()))
            .unwrap_or_else(|| destination.to_path_buf())
    });
    if canonical_source == canonical_destination {
        return true;
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        if let (Ok(a), Ok(b)) = (std::fs::metadata(source), std::fs::metadata(destination)) {
            return a.dev() == b.dev() && a.ino() == b.ino();
        }
    }
    false
}

/// What must survive export unchanged.
#[derive(Debug, Clone, PartialEq)]
pub struct Snapshot {
    pub pages: Vec<PageSnapshot>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct PageSnapshot {
    pub rotation: i64,
    pub crop_box: [i64; 4],
    pub text: String,
    pub annotations: Vec<AnnotationSnapshot>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct AnnotationSnapshot {
    pub subtype: String,
    pub rect: [i64; 4],
    pub contents: Option<String>,
    pub name: Option<String>,
    pub field_name: Option<String>,
    pub field_value: Option<String>,
    pub appearance_state: Option<String>,
}

impl Snapshot {
    pub fn of(bytes: &[u8]) -> Option<Self> {
        let document = structure::parse(bytes).ok()?;
        let texts = engine::page_texts(bytes).ok()?;
        let pages = structure::page_ids(&document);
        if pages.len() != texts.len() {
            return None;
        }
        Some(Self {
            pages: pages
                .into_iter()
                .zip(texts)
                .map(|(page, text)| PageSnapshot {
                    rotation: structure::rotation(&document, page),
                    crop_box: structure::crop_box(&document, page).map(round),
                    text,
                    annotations: annotation_snapshots(&document, page),
                })
                .collect(),
        })
    }
}

fn round(value: f32) -> i64 {
    (value * 100.0).round() as i64
}

fn annotation_snapshots(document: &LoDocument, page: ObjectId) -> Vec<AnnotationSnapshot> {
    crate::annotations::annotation_ids(document, page)
        .into_iter()
        .filter_map(|id| document.get_object(id).ok()?.as_dict().ok())
        .filter(|annotation| annotation.get(b"Subtype").and_then(Object::as_name).ok() != Some(b"Popup"))
        .map(|annotation| {
            let text = |key: &[u8]| {
                annotation
                    .get(key)
                    .ok()
                    .and_then(|value| crate::annotations::text_value(document, value))
            };
            let rect = annotation
                .get(b"Rect")
                .ok()
                .and_then(|rect| crate::annotations::rect_value(document, rect))
                .map(|rect| rect.map(round))
                .unwrap_or_default();
            AnnotationSnapshot {
                subtype: annotation
                    .get(b"Subtype")
                    .and_then(Object::as_name)
                    .map(|name| String::from_utf8_lossy(name).into_owned())
                    .unwrap_or_default(),
                rect,
                contents: text(b"Contents"),
                name: text(b"NM"),
                field_name: text(b"T"),
                field_value: annotation.get(b"V").ok().map(|value| format!("{value:?}")),
                appearance_state: annotation
                    .get(b"AS")
                    .and_then(Object::as_name)
                    .ok()
                    .map(|name| String::from_utf8_lossy(name).into_owned()),
            }
        })
        .collect()
}

/// Re-encodes 8-bit RGB and gray images as JPEG, optionally downsampling so
/// the longest edge is at most `max_dimension`. Images with unusual color
/// spaces, bit depths or decode arrays are left untouched.
fn recompress_images(document: &mut LoDocument, quality: u8, max_dimension: Option<u32>) {
    let ids: Vec<ObjectId> = document.objects.keys().copied().collect();
    for id in ids {
        let Some(Object::Stream(stream)) = document.objects.get(&id) else {
            continue;
        };
        let dictionary = &stream.dict;
        if dictionary.get(b"Subtype").and_then(Object::as_name).ok() != Some(b"Image")
            || dictionary.has(b"Decode")
            || dictionary.has(b"ImageMask")
            || dictionary.has(b"Mask")
        {
            continue;
        }
        let Some(image) = decode_image(document, stream) else {
            continue;
        };
        let image = match max_dimension {
            Some(max) if image.width().max(image.height()) > max => {
                image.resize(max, max, image::imageops::FilterType::Lanczos3)
            }
            _ => image,
        };
        let is_gray = matches!(image, image::DynamicImage::ImageLuma8(_));
        let mut encoded = Vec::new();
        let mut encoder = image::codecs::jpeg::JpegEncoder::new_with_quality(&mut encoded, quality);
        let ok = if is_gray {
            encoder.encode_image(&image.to_luma8()).is_ok()
        } else {
            encoder.encode_image(&image.to_rgb8()).is_ok()
        };
        if !ok || encoded.len() >= stream.content.len() && max_dimension.is_none() {
            continue;
        }
        let (width, height) = (image.width(), image.height());
        let Some(Object::Stream(stream)) = document.objects.get_mut(&id) else {
            continue;
        };
        stream.dict.set("Filter", Object::Name(b"DCTDecode".to_vec()));
        stream.dict.remove(b"DecodeParms");
        stream.dict.set("Width", i64::from(width));
        stream.dict.set("Height", i64::from(height));
        stream.dict.set("BitsPerComponent", 8);
        stream.dict.set(
            "ColorSpace",
            Object::Name(if is_gray { b"DeviceGray".to_vec() } else { b"DeviceRGB".to_vec() }),
        );
        stream.set_content(encoded);
        stream.allows_compression = false;
    }
}

fn decode_image(document: &LoDocument, stream: &lopdf::Stream) -> Option<image::DynamicImage> {
    let dictionary = &stream.dict;
    let filter = dictionary.get(b"Filter").ok().and_then(|filter| match filter {
        Object::Name(name) => Some(name.clone()),
        Object::Array(array) if array.len() == 1 => array[0].as_name().ok().map(<[u8]>::to_vec),
        _ => None,
    });
    let color_space = dictionary.get(b"ColorSpace").ok().and_then(|space| match space {
        Object::Reference(id) => document.get_object(*id).ok().cloned(),
        other => Some(other.clone()),
    });
    let components = match color_space.as_ref()? {
        Object::Name(name) if name == b"DeviceRGB" => 3,
        Object::Name(name) if name == b"DeviceGray" => 1,
        _ => return None,
    };
    if filter.as_deref() == Some(b"DCTDecode") {
        let image = image::load_from_memory_with_format(&stream.content, image::ImageFormat::Jpeg).ok()?;
        return match (components, &image) {
            (1, image::DynamicImage::ImageLuma8(_)) | (3, image::DynamicImage::ImageRgb8(_)) => Some(image),
            _ => None,
        };
    }
    if dictionary.get(b"BitsPerComponent").and_then(Object::as_i64).ok() != Some(8) {
        return None;
    }
    let width = u32::try_from(dictionary.get(b"Width").and_then(Object::as_i64).ok()?).ok()?;
    let height = u32::try_from(dictionary.get(b"Height").and_then(Object::as_i64).ok()?).ok()?;
    let raw = match filter.as_deref() {
        None => stream.content.clone(),
        Some(b"FlateDecode") if !dictionary.has(b"DecodeParms") => stream.decompressed_content().ok()?,
        _ => return None,
    };
    if raw.len() != (width as usize) * (height as usize) * components {
        return None;
    }
    if components == 1 {
        image::GrayImage::from_raw(width, height, raw).map(image::DynamicImage::ImageLuma8)
    } else {
        image::RgbImage::from_raw(width, height, raw).map(image::DynamicImage::ImageRgb8)
    }
}
