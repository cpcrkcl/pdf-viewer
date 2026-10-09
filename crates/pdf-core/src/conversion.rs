//! Local conversion: PDF pages to images or text, and images to a new PDF.
//! Nothing is uploaded and the inputs are never modified.

use std::collections::BTreeSet;
use std::io::Cursor;
use std::path::{Path, PathBuf};

use image::{DynamicImage, ImageDecoder, ImageReader};
use lopdf::{Dictionary, Document as LoDocument, Object, Stream, dictionary};
use thiserror::Error;

use crate::error::CoreError;
use crate::{engine, raster, structure};

pub const MINIMUM_DPI: u32 = 72;
pub const MAXIMUM_DPI: u32 = 300;
pub const MAXIMUM_IMAGE_COUNT: usize = 500;
pub const MAXIMUM_INPUT_IMAGE_BYTES: u64 = 100 * 1024 * 1024;
pub const MAXIMUM_INPUT_IMAGE_PIXELS: u64 = 25_000_000;
pub const IMAGE_EXTENSIONS: [&str; 7] = ["png", "jpg", "jpeg", "tif", "tiff", "heic", "heif"];

#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum ConversionError {
    #[error("Choose one or more pages first.")]
    EmptySelection,
    #[error("One or more selected pages are no longer available.")]
    InvalidPageSelection,
    #[error("Choose an image resolution from 72 to 300 DPI.")]
    InvalidResolution,
    #[error("A requested page would exceed the safe image size limit. Choose a lower resolution.")]
    PageTooLarge,
    #[error("Page {0} could not be rendered as an image.")]
    CouldNotRenderPage(usize),
    #[error("The selected pages contain no searchable text. Run local OCR first, then try again.")]
    NoSearchableText,
    #[error("Choose one or more PNG, JPEG, HEIC, or TIFF images.")]
    NoImages,
    #[error("A single conversion can contain at most 500 images.")]
    TooManyImages,
    #[error("{0} is not a readable image.")]
    InvalidImage(String),
    #[error("{0} exceeds the safe per-image size limit.")]
    ImageTooLarge(String),
    #[error("PDFViewer could not create a valid PDF from those images.")]
    CouldNotCreatePdf,
    #[error("PDFViewer could not create a secure temporary output directory.")]
    CouldNotCreateOutputDirectory,
    #[error("PDFViewer could not write one or more converted files.")]
    CouldNotWriteOutput,
}

impl From<ConversionError> for CoreError {
    fn from(error: ConversionError) -> Self {
        CoreError::Conversion(error.to_string())
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, serde::Serialize, serde::Deserialize)]
pub enum ImageFormat {
    #[default]
    Png,
    Jpeg,
    Tiff,
}

impl ImageFormat {
    pub const ALL: [Self; 3] = [Self::Png, Self::Jpeg, Self::Tiff];

    pub fn title(self) -> &'static str {
        match self {
            Self::Png => "PNG",
            Self::Jpeg => "JPEG",
            Self::Tiff => "TIFF",
        }
    }

    pub fn extension(self) -> &'static str {
        match self {
            Self::Png => "png",
            Self::Jpeg => "jpg",
            Self::Tiff => "tiff",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConvertedFile {
    pub filename: String,
    pub data: Vec<u8>,
}

fn validate(pages: &BTreeSet<usize>, page_count: usize) -> Result<(), ConversionError> {
    if pages.is_empty() {
        return Err(ConversionError::EmptySelection);
    }
    if pages.iter().any(|page| *page >= page_count) {
        return Err(ConversionError::InvalidPageSelection);
    }
    Ok(())
}

/// One image per page, named `<base>-page-<n>.<ext>` with zero-padded numbers.
pub fn image_files(bytes: &[u8], pages: &BTreeSet<usize>, format: ImageFormat, dpi: u32, base_name: &str) -> Result<Vec<ConvertedFile>, ConversionError> {
    let infos = crate::text::page_infos(bytes).map_err(|_| ConversionError::InvalidPageSelection)?;
    validate(pages, infos.len())?;
    if !(MINIMUM_DPI..=MAXIMUM_DPI).contains(&dpi) {
        return Err(ConversionError::InvalidResolution);
    }
    let document = engine::load(bytes.to_vec(), None).map_err(|_| ConversionError::InvalidPageSelection)?;
    let base = safe_filename_component(base_name, "PDF");
    let width = infos.len().to_string().len();
    pages
        .iter()
        .map(|&index| {
            let (page_width, page_height) = infos[index].geometry.display_size();
            let scale = dpi as f32 / 72.0;
            if (page_width * scale).ceil() * (page_height * scale).ceil() > raster::MAXIMUM_PIXELS {
                return Err(ConversionError::PageTooLarge);
            }
            let rendered = raster::render_page(&document, index, infos[index].geometry, dpi as f32)
                .map_err(|_| ConversionError::CouldNotRenderPage(index + 1))?;
            let data = encode(&DynamicImage::ImageRgb8(rendered.image), format).ok_or(ConversionError::CouldNotRenderPage(index + 1))?;
            Ok(ConvertedFile {
                filename: format!("{base}-page-{:0width$}.{}", index + 1, format.extension()),
                data,
            })
        })
        .collect()
}

fn encode(image: &DynamicImage, format: ImageFormat) -> Option<Vec<u8>> {
    let mut data = Cursor::new(Vec::new());
    match format {
        ImageFormat::Png => image.write_to(&mut data, image::ImageFormat::Png).ok()?,
        ImageFormat::Tiff => image.write_to(&mut data, image::ImageFormat::Tiff).ok()?,
        ImageFormat::Jpeg => image.write_with_encoder(image::codecs::jpeg::JpegEncoder::new_with_quality(&mut data, 90)).ok()?,
    }
    let data = data.into_inner();
    (!data.is_empty()).then_some(data)
}

/// UTF-8 text of the selected pages with `--- Page n ---` separators.
pub fn searchable_text(bytes: &[u8], pages: &BTreeSet<usize>) -> Result<String, ConversionError> {
    let texts = engine::page_texts(bytes).map_err(|_| ConversionError::InvalidPageSelection)?;
    validate(pages, texts.len())?;
    let sections: Vec<String> = pages.iter().map(|&index| format!("--- Page {} ---\n{}", index + 1, texts[index].trim())).collect();
    if pages.iter().all(|&index| texts[index].trim().is_empty()) {
        return Err(ConversionError::NoSearchableText);
    }
    Ok(sections.join("\n\n") + "\n")
}

/// Builds a PDF with one page per image, in order, each page the image's
/// size at 72 DPI. JPEGs without an orientation flag are embedded unchanged.
pub fn pdf_from_images(paths: &[PathBuf]) -> Result<Vec<u8>, ConversionError> {
    if paths.is_empty() {
        return Err(ConversionError::NoImages);
    }
    if paths.len() > MAXIMUM_IMAGE_COUNT {
        return Err(ConversionError::TooManyImages);
    }
    let mut document = LoDocument::with_version("1.7");
    let pages_id = document.new_object_id();
    let mut kids = Vec::with_capacity(paths.len());
    for path in paths {
        let name = path.file_name().map(|name| name.to_string_lossy().into_owned()).unwrap_or_default();
        let (image, passthrough_jpeg) = read_image(path, &name)?;
        let (width, height) = (image.width(), image.height());
        let image_id = match passthrough_jpeg {
            Some(jpeg) => {
                let color_space = if image.color().has_color() { "DeviceRGB" } else { "DeviceGray" };
                document.add_object(Stream::new(
                    dictionary! {
                        "Type" => "XObject",
                        "Subtype" => "Image",
                        "Width" => i64::from(width),
                        "Height" => i64::from(height),
                        "ColorSpace" => color_space,
                        "BitsPerComponent" => 8,
                        "Filter" => "DCTDecode",
                    },
                    jpeg,
                ))
            }
            None => {
                let flattened = match image {
                    DynamicImage::ImageLuma8(_) => image,
                    other if !other.color().has_color() && !other.color().has_alpha() => DynamicImage::ImageLuma8(other.to_luma8()),
                    other => DynamicImage::ImageRgb8(flatten_alpha(&other)),
                };
                raster::embed_lossless(&mut document, &flattened)
            }
        };
        let content = format!("q {width} 0 0 {height} 0 0 cm /Im0 Do Q");
        let content_id = document.add_object(Stream::new(Dictionary::new(), content.into_bytes()));
        kids.push(Object::Reference(document.add_object(dictionary! {
            "Type" => "Page",
            "Parent" => pages_id,
            "MediaBox" => vec![0.into(), 0.into(), i64::from(width).into(), i64::from(height).into()],
            "Resources" => dictionary! { "XObject" => dictionary! { "Im0" => image_id } },
            "Contents" => content_id,
        })));
    }
    let count = kids.len() as i64;
    document.objects.insert(pages_id, Object::Dictionary(dictionary! { "Type" => "Pages", "Kids" => kids, "Count" => count }));
    let catalog = document.add_object(dictionary! { "Type" => "Catalog", "Pages" => pages_id });
    document.trailer.set("Root", catalog);
    let bytes = structure::serialize(&mut document).map_err(|_| ConversionError::CouldNotCreatePdf)?;
    match crate::editor::validated_page_count(&bytes) {
        Ok(count) if count == paths.len() => Ok(bytes),
        _ => Err(ConversionError::CouldNotCreatePdf),
    }
}

/// Composites transparency over white, as a printed page would show it.
fn flatten_alpha(image: &DynamicImage) -> image::RgbImage {
    let rgba = image.to_rgba8();
    image::RgbImage::from_fn(rgba.width(), rgba.height(), |x, y| {
        let [r, g, b, a] = rgba.get_pixel(x, y).0;
        let blend = |channel: u8| ((u32::from(channel) * u32::from(a) + 255 * (255 - u32::from(a))) / 255) as u8;
        image::Rgb([blend(r), blend(g), blend(b)])
    })
}

/// Decodes an image with size limits applied before decoding. Returns the
/// original bytes too when they can be embedded as-is (upright JPEG).
fn read_image(path: &Path, name: &str) -> Result<(DynamicImage, Option<Vec<u8>>), ConversionError> {
    let invalid = || ConversionError::InvalidImage(name.to_owned());
    let metadata = std::fs::symlink_metadata(path).map_err(|_| invalid())?;
    if !metadata.is_file() {
        return Err(invalid());
    }
    if metadata.len() > MAXIMUM_INPUT_IMAGE_BYTES {
        return Err(ConversionError::ImageTooLarge(name.to_owned()));
    }
    let extension = path.extension().and_then(|e| e.to_str()).map(str::to_ascii_lowercase).unwrap_or_default();
    let data = if extension == "heic" || extension == "heif" { heic_as_png(path).ok_or_else(invalid)? } else { std::fs::read(path).map_err(|_| invalid())? };
    let reader = ImageReader::new(Cursor::new(&data)).with_guessed_format().map_err(|_| invalid())?;
    let format = reader.format().ok_or_else(invalid)?;
    if !matches!(format, image::ImageFormat::Png | image::ImageFormat::Jpeg | image::ImageFormat::Tiff) {
        return Err(invalid());
    }
    let mut decoder = reader.into_decoder().map_err(|_| invalid())?;
    let (width, height) = decoder.dimensions();
    if width == 0 || height == 0 {
        return Err(invalid());
    }
    if u64::from(width) * u64::from(height) > MAXIMUM_INPUT_IMAGE_PIXELS {
        return Err(ConversionError::ImageTooLarge(name.to_owned()));
    }
    let orientation = decoder.orientation().unwrap_or(image::metadata::Orientation::NoTransforms);
    let mut image = DynamicImage::from_decoder(decoder).map_err(|_| invalid())?;
    let upright = orientation == image::metadata::Orientation::NoTransforms;
    image.apply_orientation(orientation);
    let passthrough = (format == image::ImageFormat::Jpeg && upright && matches!(image, DynamicImage::ImageRgb8(_) | DynamicImage::ImageLuma8(_))).then_some(data);
    Ok((image, passthrough))
}

/// HEIC has no pure-Rust decoder; macOS's `sips` converts it locally.
fn heic_as_png(path: &Path) -> Option<Vec<u8>> {
    if !cfg!(target_os = "macos") {
        return None;
    }
    let directory = PrivateDirectory::new(&std::env::temp_dir()).ok()?;
    let output = directory.path.join("converted.png");
    let status = std::process::Command::new("/usr/bin/sips")
        .args(["-s", "format", "png"])
        .arg(path)
        .arg("--out")
        .arg(&output)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .ok()?;
    if !status.success() {
        return None;
    }
    std::fs::read(&output).ok()
}

/// A fresh mode-0700 directory removed on drop.
pub(crate) struct PrivateDirectory {
    pub path: PathBuf,
}

impl PrivateDirectory {
    pub fn new(parent: &Path) -> std::io::Result<Self> {
        let path = parent.join(format!(".PDFViewer-{}", uuid::Uuid::new_v4()));
        let mut builder = std::fs::DirBuilder::new();
        #[cfg(unix)]
        std::os::unix::fs::DirBuilderExt::mode(&mut builder, 0o700);
        builder.create(&path)?;
        Ok(Self { path })
    }
}

impl Drop for PrivateDirectory {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.path);
    }
}

/// Writes every file into `directory` without overwriting anything: names
/// that exist get `-2`, `-3`, … suffixes. Either all files appear or none.
pub fn write_image_files(files: &[ConvertedFile], directory: &Path) -> Result<Vec<PathBuf>, ConversionError> {
    if files.is_empty() {
        return Err(ConversionError::EmptySelection);
    }
    // Staged next to the destination so the final step is a same-volume link.
    let staging = PrivateDirectory::new(directory).map_err(|_| ConversionError::CouldNotCreateOutputDirectory)?;
    let mut staged = Vec::with_capacity(files.len());
    for (index, file) in files.iter().enumerate() {
        let temporary = staging.path.join(index.to_string());
        std::fs::write(&temporary, &file.data).map_err(|_| ConversionError::CouldNotWriteOutput)?;
        staged.push(temporary);
    }
    let mut written: Vec<PathBuf> = Vec::with_capacity(files.len());
    for (file, temporary) in files.iter().zip(&staged) {
        let stem = Path::new(&file.filename).file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
        let extension = Path::new(&file.filename).extension().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
        let (stem, extension) = (safe_filename_component(&stem, "Page"), safe_filename_extension(&extension));
        let mut linked = None;
        for sequence in 1..=10_000 {
            let suffix = if sequence == 1 { String::new() } else { format!("-{sequence}") };
            let candidate = directory.join(format!("{stem}{suffix}.{extension}"));
            // A hard link never replaces an existing file.
            match std::fs::hard_link(temporary, &candidate) {
                Ok(()) => {
                    linked = Some(candidate);
                    break;
                }
                Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
                Err(_) => break,
            }
        }
        match linked {
            Some(path) => written.push(path),
            None => {
                for path in &written {
                    let _ = std::fs::remove_file(path);
                }
                return Err(ConversionError::CouldNotWriteOutput);
            }
        }
    }
    Ok(written)
}

/// Atomically writes `text` to `destination`.
pub fn write_text(text: &str, destination: &Path) -> Result<(), ConversionError> {
    if text.is_empty() {
        return Err(ConversionError::NoSearchableText);
    }
    let parent = destination.parent().ok_or(ConversionError::CouldNotWriteOutput)?;
    let staging = PrivateDirectory::new(parent).map_err(|_| ConversionError::CouldNotWriteOutput)?;
    let temporary = staging.path.join("text");
    std::fs::write(&temporary, text.as_bytes()).map_err(|_| ConversionError::CouldNotWriteOutput)?;
    std::fs::rename(&temporary, destination).map_err(|_| ConversionError::CouldNotWriteOutput)
}

pub fn safe_filename_component(candidate: &str, fallback: &str) -> String {
    let sanitized: String = candidate.chars().map(|c| if matches!(c, '/' | ':' | '\\') || c.is_control() { '-' } else { c }).collect();
    let sanitized = sanitized.trim();
    if sanitized.is_empty() || sanitized == "." || sanitized == ".." { fallback.to_owned() } else { sanitized.chars().take(120).collect() }
}

fn safe_filename_extension(candidate: &str) -> String {
    let filtered: String = candidate.chars().filter(|c| c.is_alphanumeric()).take(12).collect::<String>().to_lowercase();
    if filtered.is_empty() { "bin".into() } else { filtered }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn filenames_are_sanitized() {
        assert_eq!(safe_filename_component("a/b:c\\d\u{7}", "PDF"), "a-b-c-d-");
        assert_eq!(safe_filename_component("  ..  ", "PDF"), "PDF");
        assert_eq!(safe_filename_extension("t.i/f"), "tif");
        assert_eq!(safe_filename_extension("//"), "bin");
    }
}
