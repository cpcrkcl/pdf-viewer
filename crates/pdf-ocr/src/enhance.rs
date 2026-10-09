//! Deterministic scan enhancement (the Core Image pipeline, in Rust).

use image::{DynamicImage, GrayImage, Luma};
use imageproc::filter::{gaussian_blur_f32, median_filter};
#[cfg(target_os = "macos")]
use imageproc::geometric_transformations::{Border, Interpolation, Projection, warp_into};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Enhancement {
    #[default]
    None,
    Grayscale,
    CleanScan,
}

impl Enhancement {
    pub const ALL: [Self; 3] = [Self::None, Self::Grayscale, Self::CleanScan];

    pub fn title(self) -> &'static str {
        match self {
            Self::None => "No Enhancement",
            Self::Grayscale => "Grayscale",
            Self::CleanScan => "Clean Scan",
        }
    }

    pub fn summary(self) -> &'static str {
        match self {
            Self::None => "Keeps the rendered page appearance unchanged.",
            Self::Grayscale => "Removes color while preserving tonal detail.",
            Self::CleanScan => {
                "Corrects perspective and deskew, reduces noise and shadows, whitens the background, increases contrast, and sharpens text."
            }
        }
    }
}

pub fn enhance(image: DynamicImage, preset: Enhancement) -> DynamicImage {
    match preset {
        Enhancement::None => image,
        Enhancement::Grayscale => DynamicImage::ImageLuma8(image.to_luma8()),
        Enhancement::CleanScan => {
            let straightened = straighten(&image).unwrap_or(image);
            DynamicImage::ImageLuma8(clean(&straightened.to_luma8()))
        }
    }
}

/// Perspective-corrects to the detected page edges, if Vision finds them.
fn straighten(image: &DynamicImage) -> Option<DynamicImage> {
    #[cfg(target_os = "macos")]
    {
        let quad = crate::vision::detect_page_quad(image)?;
        let (width, height) = (image.width() as f32, image.height() as f32);
        // Vision corners are normalized with a lower-left origin.
        let pixels = quad.map(|(x, y)| (x * width, (1.0 - y) * height));
        let target_width = distance(pixels[0], pixels[1]).max(distance(pixels[3], pixels[2])).round();
        let target_height = distance(pixels[0], pixels[3]).max(distance(pixels[1], pixels[2])).round();
        if target_width < 16.0 || target_height < 16.0 {
            return None;
        }
        let destination = [(0.0, 0.0), (target_width, 0.0), (target_width, target_height), (0.0, target_height)];
        let projection = Projection::from_control_points(pixels, destination)?;
        let source = image.to_rgb8();
        let mut output = image::RgbImage::new(target_width as u32, target_height as u32);
        warp_into(&source, projection, Interpolation::Bilinear, Border::Constant(image::Rgb([255, 255, 255])), &mut output);
        Some(DynamicImage::ImageRgb8(output))
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = image;
        None
    }
}

#[cfg(target_os = "macos")]
fn distance(a: (f32, f32), b: (f32, f32)) -> f32 {
    (a.0 - b.0).hypot(a.1 - b.1)
}

/// Shadow flattening, background whitening, denoise, contrast and unsharp mask.
pub fn clean(gray: &GrayImage) -> GrayImage {
    // Divide by an estimate of the bare paper to remove shadows and tint.
    let background = paper(gray);
    let mut flattened = GrayImage::new(gray.width(), gray.height());
    for (x, y, pixel) in flattened.enumerate_pixels_mut() {
        let value = f32::from(gray.get_pixel(x, y)[0]);
        let paper = f32::from(background.get_pixel(x, y)[0]).max(1.0);
        *pixel = Luma([((value / paper) * 255.0).clamp(0.0, 255.0) as u8]);
    }
    let denoised = median_filter(&flattened, 1, 1);
    let blurred = gaussian_blur_f32(&denoised, 1.2);
    let mut output = GrayImage::new(gray.width(), gray.height());
    for (x, y, pixel) in output.enumerate_pixels_mut() {
        let value = f32::from(denoised.get_pixel(x, y)[0]);
        let sharpened = value + 0.45 * (value - f32::from(blurred.get_pixel(x, y)[0]));
        // Contrast around a high midpoint pushes the paper to white.
        let contrasted = (sharpened - 128.0) * 1.28 + 128.0 + 15.0;
        let whitened = if contrasted > 225.0 { 255.0 } else { contrasted };
        *pixel = Luma([whitened.clamp(0.0, 255.0) as u8]);
    }
    output
}

/// The page with ink removed: the brightest value around each block, smoothed.
/// Works at 1/8 resolution so it stays cheap on 25-megapixel pages.
fn paper(gray: &GrayImage) -> GrayImage {
    const BLOCK: u32 = 8;
    const REACH: i64 = 2;
    let (width, height) = (gray.width().div_ceil(BLOCK), gray.height().div_ceil(BLOCK));
    let mut pooled = GrayImage::new(width, height);
    for (x, y, pixel) in gray.enumerate_pixels() {
        let target = pooled.get_pixel_mut(x / BLOCK, y / BLOCK);
        target[0] = target[0].max(pixel[0]);
    }
    let mut widened = GrayImage::new(width, height);
    for (x, y, pixel) in widened.enumerate_pixels_mut() {
        let mut brightest = 0;
        for dy in -REACH..=REACH {
            for dx in -REACH..=REACH {
                let (nx, ny) = (i64::from(x) + dx, i64::from(y) + dy);
                if nx >= 0 && ny >= 0 && nx < i64::from(width) && ny < i64::from(height) {
                    brightest = brightest.max(pooled.get_pixel(nx as u32, ny as u32)[0]);
                }
            }
        }
        *pixel = Luma([brightest]);
    }
    let smoothed = gaussian_blur_f32(&widened, 2.0);
    image::imageops::resize(&smoothed, gray.width(), gray.height(), image::imageops::FilterType::Triangle)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn clean_scan_whitens_shadowed_paper_and_keeps_ink_dark() {
        let mut page = GrayImage::from_pixel(200, 200, Luma([200]));
        for y in 0..200 {
            for x in 0..200 {
                // A shadow gradient across the page plus a dark ink bar.
                let shade = 200 - (x / 4) as u8;
                let ink = (90..110).contains(&y) && (40..160).contains(&x);
                page.put_pixel(x, y, Luma([if ink { 30 } else { shade }]));
            }
        }
        let cleaned = clean(&page);
        assert!(cleaned.get_pixel(10, 20)[0] > 240, "paper becomes white");
        assert!(cleaned.get_pixel(190, 20)[0] > 240, "shadowed paper becomes white");
        assert!(cleaned.get_pixel(100, 100)[0] < 80, "ink stays dark");
    }
}
