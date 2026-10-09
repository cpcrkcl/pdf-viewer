//! Apple Vision text recognition and page-edge detection. Runs locally.

use objc2::AllocAnyThread;
use objc2::rc::Retained;
use objc2_foundation::{NSArray, NSData, NSDictionary, NSString};
use objc2_vision::{
    VNDetectRectanglesRequest, VNImageRequestHandler, VNRecognizeTextRequest, VNRequest, VNRequestTextRecognitionLevel,
};

use crate::{OcrError, RecognizedLine};

fn handler(image: &image::DynamicImage) -> Result<Retained<VNImageRequestHandler>, OcrError> {
    let mut png = Vec::new();
    image
        .write_to(&mut std::io::Cursor::new(&mut png), image::ImageFormat::Png)
        .map_err(|_| OcrError::CouldNotRenderPage)?;
    let data = NSData::with_bytes(&png);
    let options = NSDictionary::new();
    Ok(VNImageRequestHandler::initWithData_options(VNImageRequestHandler::alloc(), &data, &options))
}

/// Recognized lines, top to bottom then left to right. Bounding boxes are
/// normalized with the origin at the image's lower-left corner.
pub fn recognize_text(image: &image::DynamicImage, language: Option<&str>, minimum_confidence: f32) -> Result<Vec<RecognizedLine>, OcrError> {
    let handler = handler(image)?;
    let request = VNRecognizeTextRequest::new();
    request.setRecognitionLevel(VNRequestTextRecognitionLevel::Accurate);
    request.setUsesLanguageCorrection(true);
    match language {
        Some(language) => {
            request.setAutomaticallyDetectsLanguage(false);
            request.setRecognitionLanguages(&NSArray::from_retained_slice(&[NSString::from_str(language)]));
        }
        None => request.setAutomaticallyDetectsLanguage(true),
    }
    let requests: Retained<NSArray<VNRequest>> = NSArray::from_retained_slice(&[Retained::into_super(Retained::into_super(request.clone()))]);
    handler.performRequests_error(&requests).map_err(|_| OcrError::RecognitionFailed)?;
    let mut lines = Vec::new();
    if let Some(results) = request.results() {
        for observation in results.iter() {
            let Some(candidate) = observation.topCandidates(1).firstObject() else { continue };
            let text = candidate.string().to_string().trim().to_owned();
            let confidence = candidate.confidence();
            if text.is_empty() || confidence < minimum_confidence {
                continue;
            }
            let bounds = unsafe { observation.boundingBox() };
            lines.push(RecognizedLine {
                text,
                x: bounds.origin.x as f32,
                y: bounds.origin.y as f32,
                width: bounds.size.width as f32,
                height: bounds.size.height as f32,
                confidence,
            });
        }
    }
    lines.sort_by(|a, b| {
        let (top_a, top_b) = (a.y + a.height, b.y + b.height);
        if (top_a - top_b).abs() > 0.01 { top_b.total_cmp(&top_a) } else { a.x.total_cmp(&b.x) }
    });
    Ok(lines)
}

/// The dominant document quadrilateral as normalized (lower-left origin)
/// corners: top-left, top-right, bottom-right, bottom-left.
pub fn detect_page_quad(image: &image::DynamicImage) -> Option<[(f32, f32); 4]> {
    let handler = handler(image).ok()?;
    let request = unsafe { VNDetectRectanglesRequest::new() };
    unsafe {
        request.setMaximumObservations(1);
        request.setMinimumConfidence(0.75);
        request.setMinimumSize(0.5);
        request.setQuadratureTolerance(20.0);
    }
    let requests: Retained<NSArray<VNRequest>> = NSArray::from_retained_slice(&[Retained::into_super(Retained::into_super(request.clone()))]);
    handler.performRequests_error(&requests).ok()?;
    let observation = unsafe { request.results() }?.firstObject()?;
    let point = |p: objc2_core_foundation::CGPoint| (p.x as f32, p.y as f32);
    unsafe {
        Some([
            point(observation.topLeft()),
            point(observation.topRight()),
            point(observation.bottomRight()),
            point(observation.bottomLeft()),
        ])
    }
}
