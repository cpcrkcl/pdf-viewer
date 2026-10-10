//! Rasterizing pages and replacing pages with images.

use lopdf::{Dictionary, Document as LoDocument, Object, ObjectId, Stream, dictionary};
use pdfium_render::prelude::*;

use crate::error::{CoreError, CoreResult};
use crate::geometry::PageGeometry;
use crate::structure;

pub const MAXIMUM_PIXELS: f32 = 25_000_000.0;

/// A page rendered upright (rotation applied) with its scale in px/pt.
pub struct RenderedPage {
    pub image: image::RgbImage,
    pub scale: f32,
    pub geometry: PageGeometry,
}

impl RenderedPage {
    /// Display-space points → pixel coordinates.
    pub fn to_pixels(&self, point: (f32, f32)) -> (f32, f32) {
        (point.0 * self.scale, point.1 * self.scale)
    }

    /// Displayed size in points.
    pub fn size_points(&self) -> (f32, f32) {
        self.geometry.display_size()
    }
}

/// Renders `page_index` at `dpi`, capped to `MAXIMUM_PIXELS`, with
/// annotations and form data drawn.
pub fn render_page(document: &PdfDocument, page_index: usize, geometry: PageGeometry, dpi: f32) -> CoreResult<RenderedPage> {
    let (width, height) = geometry.display_size();
    if !(width >= 2.0 && height >= 2.0) {
        return Err(CoreError::CouldNotRasterize);
    }
    let requested = (dpi / 72.0).max(1.0);
    let scale = requested.min((MAXIMUM_PIXELS / (width * height)).sqrt());
    let pixel_width = (width * scale).ceil().max(1.0) as i32;
    let page = document.pages().get(page_index as PdfPageIndex).map_err(|_| CoreError::CouldNotRasterize)?;
    let config = PdfRenderConfig::new()
        .set_target_width(pixel_width)
        .render_annotations(true)
        .render_form_data(true)
        .use_print_quality(true);
    let bitmap = page.render_with_config(&config).map_err(|_| CoreError::CouldNotRasterize)?;
    let image = bitmap.as_image().map_err(|_| CoreError::CouldNotRasterize)?.into_rgb8();
    let actual_scale = image.width() as f32 / width;
    Ok(RenderedPage {
        image,
        scale: actual_scale,
        geometry,
    })
}

/// Embeds an RGB or gray image losslessly (Flate).
pub fn embed_lossless(document: &mut LoDocument, image: &image::DynamicImage) -> ObjectId {
    let (color_space, data) = match image {
        image::DynamicImage::ImageLuma8(gray) => ("DeviceGray", gray.as_raw().clone()),
        other => ("DeviceRGB", other.to_rgb8().into_raw()),
    };
    let mut stream = Stream::new(
        dictionary! {
            "Type" => "XObject",
            "Subtype" => "Image",
            "Width" => i64::from(image.width()),
            "Height" => i64::from(image.height()),
            "ColorSpace" => color_space,
            "BitsPerComponent" => 8,
        },
        data,
    );
    let _ = stream.compress();
    document.add_object(stream)
}

/// Replaces a page's content, in place, with a full-page image of
/// `size_points`, plus optional extra content drawn after it (an invisible
/// OCR text layer). Everything else on the page — annotations, old
/// resources, thumbnails, structure links — is dropped.
pub fn replace_page_with_image(
    document: &mut LoDocument,
    page: ObjectId,
    image: ObjectId,
    size_points: (f32, f32),
    extra_content: Option<(String, Dictionary)>,
) -> CoreResult<()> {
    let parent = structure::page_dictionary(document, page)?.get(b"Parent").cloned().map_err(|_| CoreError::InvalidPdf)?;
    let (width, height) = size_points;
    let mut content = format!("q {width:.4} 0 0 {height:.4} 0 0 cm /PDFViewerPageImage Do Q\n");
    let mut resources = dictionary! { "XObject" => dictionary! { "PDFViewerPageImage" => image } };
    if let Some((extra, extra_resources)) = extra_content {
        content.push_str(&extra);
        for (key, value) in extra_resources.iter() {
            resources.set(key.clone(), value.clone());
        }
    }
    let mut stream = Stream::new(Dictionary::new(), content.into_bytes());
    let _ = stream.compress();
    let contents = document.add_object(stream);
    let replacement = dictionary! {
        "Type" => "Page",
        "Parent" => parent,
        "MediaBox" => vec![0.into(), 0.into(), width.into(), height.into()],
        "Resources" => resources,
        "Contents" => contents,
    };
    document.objects.insert(page, Object::Dictionary(replacement));
    Ok(())
}
