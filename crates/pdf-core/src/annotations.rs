//! Annotations PDFViewer creates ("owned" annotations) and read-only access
//! to everything else on a page.
//!
//! Ownership is recorded exactly as the Swift app did, so documents round
//! trip between versions: `/NM` and `/PDFViewerID` hold
//! `pdfviewer:<lowercase uuid>`. Annotations without that marker are never
//! modified.

use base64::Engine as _;
use lopdf::{Dictionary, Document as LoDocument, Object, ObjectId, StringFormat, dictionary};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::appearance::{self, Appearance, MarkupStyle, Rgba};
use crate::error::{CoreError, CoreResult};
use crate::geometry::PdfBox;
use crate::structure;

pub const ID_PREFIX: &str = "pdfviewer:";
const ID_KEY: &str = "PDFViewerID";
const SIGNATURE_DATA_KEY: &str = "PDFViewerSignatureData";
const SIGNATURE_ASPECT_KEY: &str = "PDFViewerSignatureAspectRatio";
const SIGNATURE_ROTATION_KEY: &str = "PDFViewerSignatureRotation";
const CUSTOM_STAMP_KEY: &str = "PDFViewerCustomStamp";
const AUTHOR: &str = "PDFViewer";

pub const MAXIMUM_IMAGE_BYTES: usize = 25 * 1024 * 1024;
pub const MAXIMUM_IMAGE_PIXELS: u64 = 25_000_000;
pub const MAXIMUM_NOTE_LENGTH: usize = 10_000;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct AnnotationId(pub Uuid);

impl AnnotationId {
    pub fn new() -> Self {
        Self(Uuid::new_v4())
    }

    pub fn pdf_name(&self) -> String {
        format!("{ID_PREFIX}{}", self.0.as_hyphenated().to_string().to_lowercase())
    }

    pub fn parse(name: &str) -> Option<Self> {
        name.strip_prefix(ID_PREFIX).and_then(|rest| Uuid::parse_str(rest).ok()).map(Self)
    }
}

impl Default for AnnotationId {
    fn default() -> Self {
        Self::new()
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum AnnotationKind {
    Highlight,
    Underline,
    Strikethrough,
    Ink,
    TextNote,
    Rectangle,
    Oval,
    Line,
    Arrow,
    Stamp,
    Signature,
    /// Anything PDFViewer doesn't model (links, widgets, popups, …).
    Other,
}

impl AnnotationKind {
    pub fn title(self) -> &'static str {
        match self {
            Self::Highlight => "Highlight",
            Self::Underline => "Underline",
            Self::Strikethrough => "Strikethrough",
            Self::Ink => "Freehand",
            Self::TextNote => "Text Note",
            Self::Rectangle => "Rectangle",
            Self::Oval => "Oval",
            Self::Line => "Line",
            Self::Arrow => "Arrow",
            Self::Stamp => "Stamp",
            Self::Signature => "Visual Signature",
            Self::Other => "Annotation",
        }
    }

    pub fn has_line_width(self) -> bool {
        matches!(self, Self::Ink | Self::Rectangle | Self::Oval | Self::Line | Self::Arrow)
    }

    pub fn has_color(self) -> bool {
        !matches!(self, Self::Signature | Self::Stamp | Self::Other)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum MarkupKind {
    Highlight,
    Underline,
    Strikethrough,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum ShapeKind {
    Rectangle,
    Oval,
    Line,
    Arrow,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
pub enum LineWidth {
    Hairline,
    Fine,
    #[default]
    Standard,
    Bold,
    ExtraBold,
    Marker,
}

impl LineWidth {
    pub const ALL: [Self; 6] = [Self::Hairline, Self::Fine, Self::Standard, Self::Bold, Self::ExtraBold, Self::Marker];

    pub fn points(self) -> f32 {
        match self {
            Self::Hairline => 0.75,
            Self::Fine => 1.5,
            Self::Standard => 3.0,
            Self::Bold => 5.0,
            Self::ExtraBold => 8.0,
            Self::Marker => 12.0,
        }
    }

    pub fn title(self) -> &'static str {
        match self {
            Self::Hairline => "Hairline",
            Self::Fine => "Fine",
            Self::Standard => "Standard",
            Self::Bold => "Bold",
            Self::ExtraBold => "Extra Bold",
            Self::Marker => "Marker",
        }
    }

    pub fn nearest(points: f32) -> Self {
        *Self::ALL
            .iter()
            .min_by(|a, b| (a.points() - points).abs().total_cmp(&(b.points() - points).abs()))
            .unwrap()
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum StampPreset {
    Approved,
    Draft,
    Confidential,
    Final,
    TopSecret,
}

impl StampPreset {
    pub const ALL: [Self; 5] = [Self::Approved, Self::Draft, Self::Confidential, Self::Final, Self::TopSecret];

    pub fn title(self) -> &'static str {
        match self {
            Self::Approved => "Approved",
            Self::Draft => "Draft",
            Self::Confidential => "Confidential",
            Self::Final => "Final",
            Self::TopSecret => "Top Secret",
        }
    }

    pub fn pdf_name(self) -> &'static str {
        match self {
            Self::TopSecret => "TopSecret",
            other => other.title(),
        }
    }

    fn from_pdf_name(name: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|preset| preset.pdf_name() == name)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
pub enum SignatureSize {
    Small,
    #[default]
    Medium,
    Large,
}

impl SignatureSize {
    pub const ALL: [Self; 3] = [Self::Small, Self::Medium, Self::Large];

    pub fn width(self) -> f32 {
        match self {
            Self::Small => 96.0,
            Self::Medium => 144.0,
            Self::Large => 216.0,
        }
    }

    pub fn title(self) -> &'static str {
        match self {
            Self::Small => "Small",
            Self::Medium => "Medium",
            Self::Large => "Large",
        }
    }
}

/// The six palette colors (macOS system colors) plus arbitrary colors.
pub mod palette {
    use super::Rgba;
    pub const YELLOW: Rgba = Rgba::new(1.0, 0.8, 0.0, 1.0);
    pub const GREEN: Rgba = Rgba::new(0.2, 0.78, 0.35, 1.0);
    pub const BLUE: Rgba = Rgba::new(0.0, 0.48, 1.0, 1.0);
    pub const PINK: Rgba = Rgba::new(1.0, 0.18, 0.33, 1.0);
    pub const RED: Rgba = Rgba::new(1.0, 0.23, 0.19, 1.0);
    pub const BLACK: Rgba = Rgba::new(0.0, 0.0, 0.0, 1.0);
    pub const ALL: [(&str, Rgba); 6] = [
        ("Yellow", YELLOW),
        ("Green", GREEN),
        ("Blue", BLUE),
        ("Pink", PINK),
        ("Red", RED),
        ("Black", BLACK),
    ];
}

/// A page annotation as the reader needs it for hit-testing and listing.
#[derive(Debug, Clone, PartialEq)]
pub struct AnnotationInfo {
    pub page: usize,
    pub object: ObjectId,
    pub kind: AnnotationKind,
    pub owned: Option<AnnotationId>,
    pub rect: PdfBox,
    pub label: String,
    pub color: Option<Rgba>,
    pub line_width: Option<f32>,
    pub contents: Option<String>,
    pub ink: Vec<Vec<(f32, f32)>>,
    pub rotation_quarter_turns: i64,
    /// A visual signature or custom image stamp.
    pub has_image: bool,
}

// MARK: Reading

/// Indirect annotation ids on a page, in `/Annots` order.
pub fn annotation_ids(document: &LoDocument, page: ObjectId) -> Vec<ObjectId> {
    structure::page_dictionary(document, page)
        .ok()
        .and_then(|dictionary| dictionary.get(b"Annots").ok())
        .and_then(|annots| match annots {
            Object::Reference(id) => document.get_object(*id).ok()?.as_array().ok(),
            other => other.as_array().ok(),
        })
        .map(|array| array.iter().filter_map(|item| item.as_reference().ok()).collect())
        .unwrap_or_default()
}

/// Decodes a PDF text string (PDFDocEncoding or UTF-16BE with BOM).
pub fn text_value(document: &LoDocument, value: &Object) -> Option<String> {
    match value {
        Object::Reference(id) => text_value(document, document.get_object(*id).ok()?),
        Object::String(bytes, _) => {
            Some(lopdf::decode_text_string(value).unwrap_or_else(|_| String::from_utf8_lossy(bytes).into_owned()))
        }
        Object::Name(name) => Some(String::from_utf8_lossy(name).into_owned()),
        _ => None,
    }
}

/// A normalized `[x0, y0, x1, y1]` rectangle.
pub fn rect_value(document: &LoDocument, value: &Object) -> Option<[f32; 4]> {
    let numbers = number_array(document, value)?;
    if numbers.len() != 4 {
        return None;
    }
    let rect = PdfBox::new(numbers[0], numbers[1], numbers[2], numbers[3]);
    rect.is_finite().then_some(rect.to_array())
}

fn number_array(document: &LoDocument, value: &Object) -> Option<Vec<f32>> {
    let array = match value {
        Object::Reference(id) => document.get_object(*id).ok()?.as_array().ok()?,
        other => other.as_array().ok()?,
    };
    array
        .iter()
        .map(|item| match item {
            Object::Reference(id) => document.get_object(*id).ok()?.as_float().ok(),
            other => other.as_float().ok(),
        })
        .collect()
}

pub fn owned_id(document: &LoDocument, dictionary: &Dictionary) -> Option<AnnotationId> {
    [b"NM".as_slice(), ID_KEY.as_bytes()]
        .into_iter()
        .filter_map(|key| dictionary.get(key).ok())
        .filter_map(|value| text_value(document, value))
        .find_map(|name| AnnotationId::parse(&name))
}

fn subtype(dictionary: &Dictionary) -> &[u8] {
    dictionary.get(b"Subtype").and_then(Object::as_name).unwrap_or(b"")
}

fn classify(document: &LoDocument, dictionary: &Dictionary) -> AnnotationKind {
    match subtype(dictionary) {
        b"Highlight" => AnnotationKind::Highlight,
        b"Underline" => AnnotationKind::Underline,
        b"StrikeOut" => AnnotationKind::Strikethrough,
        b"Ink" => AnnotationKind::Ink,
        b"Text" => AnnotationKind::TextNote,
        b"Square" => AnnotationKind::Rectangle,
        b"Circle" => AnnotationKind::Oval,
        b"Line" => {
            let arrow = dictionary
                .get(b"LE")
                .and_then(Object::as_array)
                .ok()
                .and_then(|ends| ends.get(1))
                .and_then(|end| end.as_name().ok())
                .is_some_and(|name| name == b"ClosedArrow" || name == b"OpenArrow");
            if arrow { AnnotationKind::Arrow } else { AnnotationKind::Line }
        }
        b"Stamp" => {
            let has_image = dictionary.has(SIGNATURE_DATA_KEY.as_bytes());
            let custom = dictionary
                .get(CUSTOM_STAMP_KEY.as_bytes())
                .and_then(Object::as_bool)
                .unwrap_or(false);
            let _ = document;
            if has_image && !custom { AnnotationKind::Signature } else { AnnotationKind::Stamp }
        }
        _ => AnnotationKind::Other,
    }
}

/// Every annotation on every page (popups excluded).
pub fn annotation_index(document: &LoDocument) -> Vec<Vec<AnnotationInfo>> {
    structure::page_ids(document)
        .into_iter()
        .enumerate()
        .map(|(page_index, page)| {
            annotation_ids(document, page)
                .into_iter()
                .filter_map(|object| {
                    let dictionary = document.get_object(object).ok()?.as_dict().ok()?;
                    if subtype(dictionary) == b"Popup" {
                        return None;
                    }
                    let rect = PdfBox::from_array(rect_value(document, dictionary.get(b"Rect").ok()?)?);
                    let kind = classify(document, dictionary);
                    let owned = owned_id(document, dictionary);
                    let contents = dictionary
                        .get(b"Contents")
                        .ok()
                        .and_then(|value| text_value(document, value))
                        .map(|text| text.trim().to_owned())
                        .filter(|text| !text.is_empty());
                    let label: String = contents.clone().unwrap_or_else(|| kind.title().to_owned()).chars().take(120).collect();
                    Some(AnnotationInfo {
                        page: page_index,
                        object,
                        kind,
                        owned,
                        rect,
                        label,
                        color: color_of(document, dictionary),
                        line_width: border_width(dictionary),
                        contents,
                        ink: ink_list(document, dictionary),
                        rotation_quarter_turns: dictionary
                            .get(SIGNATURE_ROTATION_KEY.as_bytes())
                            .and_then(Object::as_i64)
                            .unwrap_or(0),
                        has_image: dictionary.has(SIGNATURE_DATA_KEY.as_bytes()),
                    })
                })
                .collect()
        })
        .collect()
}

pub fn owned_annotations(document: &LoDocument) -> Vec<AnnotationInfo> {
    annotation_index(document).into_iter().flatten().filter(|info| info.owned.is_some()).collect()
}

fn color_of(document: &LoDocument, dictionary: &Dictionary) -> Option<Rgba> {
    let components = number_array(document, dictionary.get(b"C").ok()?)?;
    let alpha = dictionary.get(b"CA").and_then(Object::as_float).unwrap_or(1.0);
    match components.as_slice() {
        [r, g, b] => Some(Rgba::new(*r, *g, *b, alpha)),
        [gray] => Some(Rgba::new(*gray, *gray, *gray, alpha)),
        _ => None,
    }
}

fn border_width(dictionary: &Dictionary) -> Option<f32> {
    dictionary
        .get(b"BS")
        .and_then(Object::as_dict)
        .and_then(|border| border.get(b"W"))
        .and_then(Object::as_float)
        .ok()
}

fn ink_list(document: &LoDocument, dictionary: &Dictionary) -> Vec<Vec<(f32, f32)>> {
    let Ok(list) = dictionary.get(b"InkList").and_then(Object::as_array) else {
        return Vec::new();
    };
    list.iter()
        .filter_map(|stroke| number_array(document, stroke))
        .map(|numbers| numbers.chunks_exact(2).map(|pair| (pair[0], pair[1])).collect())
        .collect()
}

fn quads(dictionary: &Dictionary) -> Vec<PdfBox> {
    let Ok(values) = dictionary.get(b"QuadPoints").and_then(Object::as_array) else {
        return Vec::new();
    };
    let numbers: Vec<f32> = values.iter().filter_map(|value| value.as_float().ok()).collect();
    numbers
        .chunks_exact(8)
        .map(|quad| {
            let xs = [quad[0], quad[2], quad[4], quad[6]];
            let ys = [quad[1], quad[3], quad[5], quad[7]];
            PdfBox::new(
                xs.iter().copied().fold(f32::MAX, f32::min),
                ys.iter().copied().fold(f32::MAX, f32::min),
                xs.iter().copied().fold(f32::MIN, f32::max),
                ys.iter().copied().fold(f32::MIN, f32::max),
            )
        })
        .collect()
}

fn quad_points(boxes: &[PdfBox]) -> Vec<Object> {
    // Order per the spec as implemented by viewers: upper-left, upper-right,
    // lower-left, lower-right.
    boxes
        .iter()
        .flat_map(|rect| [rect.x0, rect.y1, rect.x1, rect.y1, rect.x0, rect.y0, rect.x1, rect.y0])
        .map(Object::from)
        .collect()
}

pub fn signature_image_data(dictionary: &Dictionary) -> Option<Vec<u8>> {
    let encoded = dictionary.get(SIGNATURE_DATA_KEY.as_bytes()).ok()?;
    let text = match encoded {
        Object::String(bytes, _) => String::from_utf8_lossy(bytes).into_owned(),
        _ => return None,
    };
    if text.len() > MAXIMUM_IMAGE_BYTES.div_ceil(3) * 4 + 4 {
        return None;
    }
    let data = base64::engine::general_purpose::STANDARD.decode(text.trim()).ok()?;
    validated_image(&data).ok()?;
    Some(data)
}

/// Accepts PNG or JPEG under the size and pixel limits; returns its size.
pub fn validated_image(data: &[u8]) -> CoreResult<(u32, u32)> {
    if data.len() > MAXIMUM_IMAGE_BYTES {
        return Err(CoreError::ImageTooLarge);
    }
    let format = image::guess_format(data).map_err(|_| CoreError::InvalidImage)?;
    if !matches!(format, image::ImageFormat::Png | image::ImageFormat::Jpeg) {
        return Err(CoreError::InvalidImage);
    }
    let reader = image::ImageReader::with_format(std::io::Cursor::new(data), format);
    let (width, height) = reader.into_dimensions().map_err(|_| CoreError::InvalidImage)?;
    if width == 0 || height == 0 {
        return Err(CoreError::InvalidImage);
    }
    if u64::from(width) * u64::from(height) > MAXIMUM_IMAGE_PIXELS {
        return Err(CoreError::ImageTooLarge);
    }
    Ok((width, height))
}

// MARK: Creating

fn page_box(document: &LoDocument, page_index: usize) -> CoreResult<(ObjectId, PdfBox)> {
    let page = structure::page_id(document, page_index).map_err(|_| CoreError::InvalidAnnotation)?;
    Ok((page, PdfBox::from_array(structure::crop_box(document, page))))
}

fn now_pdf_date() -> Object {
    let now = chrono::Utc::now();
    Object::String(now.format("D:%Y%m%d%H%M%S+00'00'").to_string().into_bytes(), StringFormat::Literal)
}

fn base_dictionary(subtype: &str, rect: &PdfBox, id: AnnotationId, color: Option<Rgba>) -> Dictionary {
    let mut dictionary = dictionary! {
        "Type" => "Annot",
        "Subtype" => subtype,
        "Rect" => vec![rect.x0.into(), rect.y0.into(), rect.x1.into(), rect.y1.into()],
        "F" => 4,
        "T" => Object::string_literal(AUTHOR),
        "M" => now_pdf_date(),
        "NM" => Object::string_literal(id.pdf_name()),
        ID_KEY => Object::string_literal(id.pdf_name()),
    };
    if let Some(color) = color {
        dictionary.set("C", color.to_pdf_array());
        if color.a < 0.999 {
            dictionary.set("CA", color.a);
        }
    }
    dictionary
}

fn attach(document: &mut LoDocument, page: ObjectId, mut dictionary: Dictionary) -> CoreResult<ObjectId> {
    dictionary.set("P", page);
    let annotation = document.add_object(dictionary);
    let existing = structure::page_dictionary(document, page)?.get(b"Annots").ok().cloned();
    let mut annots = match existing {
        Some(Object::Array(array)) => array,
        Some(Object::Reference(id)) => document.get_object(id).and_then(Object::as_array).cloned().unwrap_or_default(),
        _ => Vec::new(),
    };
    annots.push(Object::Reference(annotation));
    structure::page_dictionary_mut(document, page)?.set("Annots", annots);
    regenerate_appearance(document, annotation)?;
    Ok(annotation)
}

fn finite(point: (f32, f32)) -> bool {
    point.0.is_finite() && point.1.is_finite()
}

/// One markup annotation per page entry, covering its line boxes.
pub fn add_text_markup(
    document: &mut LoDocument,
    kind: MarkupKind,
    regions: &[(usize, Vec<PdfBox>)],
    color: Rgba,
) -> CoreResult<Vec<AnnotationId>> {
    if regions.is_empty() {
        return Err(CoreError::InvalidAnnotation);
    }
    let mut ids = Vec::new();
    for (page_index, boxes) in regions {
        if boxes.is_empty() || boxes.iter().any(|rect| !rect.is_finite() || rect.is_empty()) {
            return Err(CoreError::InvalidAnnotation);
        }
        let (page, _) = page_box(document, *page_index)?;
        let bounds = boxes.iter().copied().reduce(|a, b| a.union(&b)).unwrap();
        let (subtype, alpha) = match kind {
            MarkupKind::Highlight => ("Highlight", 0.35),
            MarkupKind::Underline => ("Underline", 0.9),
            MarkupKind::Strikethrough => ("StrikeOut", 0.9),
        };
        let id = AnnotationId::new();
        let mut dictionary = base_dictionary(subtype, &bounds, id, Some(color.with_alpha(alpha)));
        dictionary.set("QuadPoints", quad_points(boxes));
        attach(document, page, dictionary)?;
        ids.push(id);
    }
    Ok(ids)
}

pub fn add_ink(
    document: &mut LoDocument,
    page_index: usize,
    points: &[(f32, f32)],
    color: Rgba,
    width: LineWidth,
) -> CoreResult<AnnotationId> {
    if points.len() < 2 || !points.iter().copied().all(finite) {
        return Err(CoreError::InvalidAnnotation);
    }
    let (page, _) = page_box(document, page_index)?;
    let inset = width.points() / 2.0 + 1.0;
    let bounds = points
        .iter()
        .fold(PdfBox::new(points[0].0, points[0].1, points[0].0, points[0].1), |rect, point| {
            rect.union(&PdfBox::new(point.0, point.1, point.0, point.1))
        })
        .inset(-inset, -inset);
    let id = AnnotationId::new();
    let mut dictionary = base_dictionary("Ink", &bounds, id, Some(color.with_alpha(0.9)));
    dictionary.set(
        "InkList",
        vec![Object::Array(points.iter().flat_map(|(x, y)| [Object::from(*x), Object::from(*y)]).collect())],
    );
    dictionary.set("BS", dictionary! { "W" => width.points(), "S" => "S" });
    attach(document, page, dictionary)?;
    Ok(id)
}

pub fn add_shape(
    document: &mut LoDocument,
    kind: ShapeKind,
    page_index: usize,
    start: (f32, f32),
    end: (f32, f32),
    color: Rgba,
    width: LineWidth,
) -> CoreResult<AnnotationId> {
    if !finite(start) || !finite(end) {
        return Err(CoreError::InvalidAnnotation);
    }
    let is_line = matches!(kind, ShapeKind::Line | ShapeKind::Arrow);
    let placement = PdfBox::from_points(start, end);
    let large_enough = if is_line {
        (end.0 - start.0).hypot(end.1 - start.1) >= 4.0
    } else {
        placement.width() >= 4.0 && placement.height() >= 4.0
    };
    if !large_enough {
        return Err(CoreError::InvalidAnnotation);
    }
    let (page, page_bounds) = page_box(document, page_index)?;
    let inset = width.points() / 2.0 + if kind == ShapeKind::Arrow { width.points() * 2.0 + 4.0 } else { 2.0 };
    let bounds = if is_line {
        placement.inset(-inset, -inset).clamped_to(&page_bounds)
    } else {
        placement.clamped_to(&page_bounds)
    };
    let subtype = match kind {
        ShapeKind::Rectangle => "Square",
        ShapeKind::Oval => "Circle",
        ShapeKind::Line | ShapeKind::Arrow => "Line",
    };
    let id = AnnotationId::new();
    let mut dictionary = base_dictionary(subtype, &bounds, id, Some(color.with_alpha(0.9)));
    dictionary.set("BS", dictionary! { "W" => width.points(), "S" => "S" });
    if is_line {
        dictionary.set("L", vec![start.0.into(), start.1.into(), end.0.into(), end.1.into()]);
        dictionary.set(
            "LE",
            vec![
                Object::Name(b"None".to_vec()),
                Object::Name(if kind == ShapeKind::Arrow { b"ClosedArrow".to_vec() } else { b"None".to_vec() }),
            ],
        );
        if kind == ShapeKind::Arrow {
            dictionary.set("IC", color.to_pdf_array());
        }
    }
    attach(document, page, dictionary)?;
    Ok(id)
}

pub fn add_stamp(document: &mut LoDocument, page_index: usize, point: (f32, f32), preset: StampPreset) -> CoreResult<AnnotationId> {
    if !finite(point) {
        return Err(CoreError::InvalidAnnotation);
    }
    let (page, page_bounds) = page_box(document, page_index)?;
    let bounds = PdfBox::new(point.0 - 72.0, point.1 - 24.0, point.0 + 72.0, point.1 + 24.0).clamped_to(&page_bounds);
    let id = AnnotationId::new();
    let mut dictionary = base_dictionary("Stamp", &bounds, id, Some(palette::RED));
    dictionary.set("Name", Object::Name(preset.pdf_name().as_bytes().to_vec()));
    dictionary.set("Contents", Object::string_literal(preset.title()));
    attach(document, page, dictionary)?;
    Ok(id)
}

pub fn add_text_note(
    document: &mut LoDocument,
    page_index: usize,
    point: (f32, f32),
    contents: &str,
    color: Rgba,
) -> CoreResult<AnnotationId> {
    let contents: String = contents.trim().chars().take(MAXIMUM_NOTE_LENGTH).collect();
    if contents.is_empty() || !finite(point) {
        return Err(CoreError::InvalidAnnotation);
    }
    let (page, page_bounds) = page_box(document, page_index)?;
    let bounds = PdfBox::new(point.0 - 12.0, point.1 - 12.0, point.0 + 12.0, point.1 + 12.0).clamped_to(&page_bounds);
    let id = AnnotationId::new();
    let mut dictionary = base_dictionary("Text", &bounds, id, Some(color.with_alpha(1.0)));
    dictionary.set("Contents", lopdf::text_string(&contents));
    dictionary.set("Name", "Note");
    attach(document, page, dictionary)?;
    Ok(id)
}

/// A visual signature or (with `custom_stamp_name`) a custom image stamp.
pub fn add_image_stamp(
    document: &mut LoDocument,
    page_index: usize,
    point: (f32, f32),
    image_data: &[u8],
    size: SignatureSize,
    custom_stamp_name: Option<&str>,
) -> CoreResult<AnnotationId> {
    if !finite(point) {
        return Err(CoreError::InvalidAnnotation);
    }
    let (width, height) = validated_image(image_data)?;
    let (page, page_bounds) = page_box(document, page_index)?;
    let aspect = width as f32 / height as f32;
    let bounds = signature_bounds(point, aspect, size, &page_bounds);
    let id = AnnotationId::new();
    let mut dictionary = base_dictionary("Stamp", &bounds, id, None);
    dictionary.set(
        SIGNATURE_DATA_KEY,
        Object::string_literal(base64::engine::general_purpose::STANDARD.encode(image_data)),
    );
    dictionary.set(SIGNATURE_ASPECT_KEY, aspect);
    dictionary.set(SIGNATURE_ROTATION_KEY, 0);
    if let Some(name) = custom_stamp_name {
        dictionary.set(CUSTOM_STAMP_KEY, true);
        let name: String = name.trim().chars().take(120).collect();
        dictionary.set("Contents", lopdf::text_string(if name.is_empty() { "Custom Stamp" } else { &name }));
    }
    attach(document, page, dictionary)?;
    Ok(id)
}

fn signature_bounds(center: (f32, f32), aspect: f32, size: SignatureSize, page: &PdfBox) -> PdfBox {
    let aspect = aspect.clamp(0.2, 8.0);
    let width = size.width().min(page.width());
    let height = (width / aspect).min(page.height());
    PdfBox::new(center.0 - width / 2.0, center.1 - height / 2.0, center.0 + width / 2.0, center.1 + height / 2.0)
        .clamped_to(page)
}

// MARK: Editing owned annotations

/// Finds an owned annotation on a page. Third-party annotations are reported
/// as read-only rather than missing.
pub fn find_owned(document: &LoDocument, page_index: usize, id: AnnotationId) -> CoreResult<ObjectId> {
    let page = structure::page_id(document, page_index).map_err(|_| CoreError::InvalidAnnotation)?;
    annotation_ids(document, page)
        .into_iter()
        .find(|object| {
            document
                .get_object(*object)
                .and_then(Object::as_dict)
                .ok()
                .and_then(|dictionary| owned_id(document, dictionary))
                == Some(id)
        })
        .ok_or(CoreError::InvalidAnnotation)
}

fn dictionary_mut(document: &mut LoDocument, object: ObjectId) -> CoreResult<&mut Dictionary> {
    document.get_object_mut(object).and_then(Object::as_dict_mut).map_err(|_| CoreError::InvalidAnnotation)
}

fn touch(document: &mut LoDocument, object: ObjectId) -> CoreResult<()> {
    dictionary_mut(document, object)?.set("M", now_pdf_date());
    Ok(())
}

/// Applies an affine map (scale then translate) to every coordinate the
/// annotation stores, then redraws it.
fn transform(document: &mut LoDocument, object: ObjectId, from: PdfBox, to: PdfBox) -> CoreResult<()> {
    let sx = to.width() / from.width().max(0.001);
    let sy = to.height() / from.height().max(0.001);
    let map = |x: f32, y: f32| (to.x0 + (x - from.x0) * sx, to.y0 + (y - from.y0) * sy);
    let dictionary = dictionary_mut(document, object)?;
    dictionary.set("Rect", vec![to.x0.into(), to.y0.into(), to.x1.into(), to.y1.into()]);
    if let Ok(Object::Array(values)) = dictionary.get(b"QuadPoints").cloned() {
        let numbers: Vec<f32> = values.iter().filter_map(|v| v.as_float().ok()).collect();
        let mapped: Vec<Object> = numbers
            .chunks_exact(2)
            .flat_map(|pair| {
                let (x, y) = map(pair[0], pair[1]);
                [Object::from(x), Object::from(y)]
            })
            .collect();
        dictionary.set("QuadPoints", mapped);
    }
    if let Ok(Object::Array(strokes)) = dictionary.get(b"InkList").cloned() {
        let mapped: Vec<Object> = strokes
            .iter()
            .filter_map(|stroke| stroke.as_array().ok())
            .map(|stroke| {
                let numbers: Vec<f32> = stroke.iter().filter_map(|v| v.as_float().ok()).collect();
                Object::Array(
                    numbers
                        .chunks_exact(2)
                        .flat_map(|pair| {
                            let (x, y) = map(pair[0], pair[1]);
                            [Object::from(x), Object::from(y)]
                        })
                        .collect(),
                )
            })
            .collect();
        dictionary.set("InkList", mapped);
    }
    if let Ok(Object::Array(line)) = dictionary.get(b"L").cloned() {
        let numbers: Vec<f32> = line.iter().filter_map(|v| v.as_float().ok()).collect();
        if numbers.len() == 4 {
            let (x1, y1) = map(numbers[0], numbers[1]);
            let (x2, y2) = map(numbers[2], numbers[3]);
            dictionary.set("L", vec![x1.into(), y1.into(), x2.into(), y2.into()]);
        }
    }
    touch(document, object)?;
    regenerate_appearance(document, object)
}

fn current_rect(document: &LoDocument, object: ObjectId) -> CoreResult<PdfBox> {
    let dictionary = document.get_object(object).and_then(Object::as_dict).map_err(|_| CoreError::InvalidAnnotation)?;
    dictionary
        .get(b"Rect")
        .ok()
        .and_then(|rect| rect_value(document, rect))
        .map(PdfBox::from_array)
        .ok_or(CoreError::InvalidAnnotation)
}

pub fn move_annotation(document: &mut LoDocument, page_index: usize, id: AnnotationId, dx: f32, dy: f32) -> CoreResult<()> {
    if !dx.is_finite() || !dy.is_finite() {
        return Err(CoreError::InvalidAnnotation);
    }
    let object = find_owned(document, page_index, id)?;
    let (_, page_bounds) = page_box(document, page_index)?;
    let from = current_rect(document, object)?;
    let to = from.offset(dx, dy).clamped_to(&page_bounds);
    transform(document, object, from, to)
}

pub fn resize_annotation(document: &mut LoDocument, page_index: usize, id: AnnotationId, scale: f32) -> CoreResult<()> {
    if !scale.is_finite() || !(0.25..=4.0).contains(&scale) {
        return Err(CoreError::InvalidAnnotation);
    }
    let object = find_owned(document, page_index, id)?;
    let (_, page_bounds) = page_box(document, page_index)?;
    let from = current_rect(document, object)?;
    let width = (from.width() * scale).max(8.0).min(page_bounds.width());
    let height = (from.height() * scale).max(8.0).min(page_bounds.height());
    let (cx, cy) = from.center();
    let to = PdfBox::new(cx - width / 2.0, cy - height / 2.0, cx + width / 2.0, cy + height / 2.0).clamped_to(&page_bounds);
    transform(document, object, from, to)
}

/// Moves an annotation so its rect becomes `target` (used by drag handles).
pub fn set_annotation_rect(document: &mut LoDocument, page_index: usize, id: AnnotationId, target: PdfBox) -> CoreResult<()> {
    if !target.is_finite() || target.width() < 4.0 || target.height() < 4.0 {
        return Err(CoreError::InvalidAnnotation);
    }
    let object = find_owned(document, page_index, id)?;
    let (_, page_bounds) = page_box(document, page_index)?;
    let from = current_rect(document, object)?;
    transform(document, object, from, target.clamped_to(&page_bounds))
}

pub fn set_color(document: &mut LoDocument, page_index: usize, id: AnnotationId, color: Rgba) -> CoreResult<()> {
    let object = find_owned(document, page_index, id)?;
    let dictionary = dictionary_mut(document, object)?;
    let alpha = match subtype(dictionary) {
        b"Highlight" => 0.35,
        b"Text" => 1.0,
        b"Stamp" => return Err(CoreError::InvalidAnnotation),
        _ => 0.9,
    };
    dictionary.set("C", color.to_pdf_array());
    if alpha < 0.999 {
        dictionary.set("CA", alpha);
    } else {
        dictionary.remove(b"CA");
    }
    if dictionary.has(b"IC") {
        dictionary.set("IC", color.to_pdf_array());
    }
    touch(document, object)?;
    regenerate_appearance(document, object)
}

pub fn set_line_width(document: &mut LoDocument, page_index: usize, id: AnnotationId, width: LineWidth) -> CoreResult<()> {
    let object = find_owned(document, page_index, id)?;
    let dictionary = dictionary_mut(document, object)?;
    if !matches!(subtype(dictionary), b"Ink" | b"Square" | b"Circle" | b"Line") {
        return Err(CoreError::InvalidAnnotation);
    }
    dictionary.set("BS", dictionary! { "W" => width.points(), "S" => "S" });
    touch(document, object)?;
    regenerate_appearance(document, object)
}

pub fn set_note_contents(document: &mut LoDocument, page_index: usize, id: AnnotationId, contents: &str) -> CoreResult<()> {
    let contents: String = contents.trim().chars().take(MAXIMUM_NOTE_LENGTH).collect();
    if contents.is_empty() {
        return Err(CoreError::InvalidAnnotation);
    }
    let object = find_owned(document, page_index, id)?;
    let dictionary = dictionary_mut(document, object)?;
    if subtype(dictionary) != b"Text" {
        return Err(CoreError::InvalidAnnotation);
    }
    dictionary.set("Contents", lopdf::text_string(&contents));
    touch(document, object)
}

pub fn note_contents(document: &LoDocument, page_index: usize, id: AnnotationId) -> Option<String> {
    let object = find_owned(document, page_index, id).ok()?;
    let dictionary = document.get_object(object).ok()?.as_dict().ok()?;
    (subtype(dictionary) == b"Text")
        .then(|| dictionary.get(b"Contents").ok().and_then(|value| text_value(document, value)))
        .flatten()
}

pub fn rotate_image_stamp(document: &mut LoDocument, page_index: usize, id: AnnotationId, clockwise: bool) -> CoreResult<()> {
    let object = find_owned(document, page_index, id)?;
    let (_, page_bounds) = page_box(document, page_index)?;
    let rect = current_rect(document, object)?;
    let dictionary = dictionary_mut(document, object)?;
    if !dictionary.has(SIGNATURE_DATA_KEY.as_bytes()) {
        return Err(CoreError::InvalidAnnotation);
    }
    let turns = dictionary.get(SIGNATURE_ROTATION_KEY.as_bytes()).and_then(Object::as_i64).unwrap_or(0);
    dictionary.set(SIGNATURE_ROTATION_KEY, (turns + if clockwise { 1 } else { -1 }).rem_euclid(4));
    let (cx, cy) = rect.center();
    let swapped = PdfBox::new(
        cx - rect.height() / 2.0,
        cy - rect.width() / 2.0,
        cx + rect.height() / 2.0,
        cy + rect.width() / 2.0,
    )
    .clamped_to(&page_bounds);
    dictionary.set("Rect", vec![swapped.x0.into(), swapped.y0.into(), swapped.x1.into(), swapped.y1.into()]);
    touch(document, object)?;
    regenerate_appearance(document, object)
}

pub fn set_image_stamp_size(document: &mut LoDocument, page_index: usize, id: AnnotationId, size: SignatureSize) -> CoreResult<()> {
    let object = find_owned(document, page_index, id)?;
    let (_, page_bounds) = page_box(document, page_index)?;
    let rect = current_rect(document, object)?;
    let dictionary = dictionary_mut(document, object)?;
    let aspect = dictionary
        .get(SIGNATURE_ASPECT_KEY.as_bytes())
        .and_then(Object::as_float)
        .ok()
        .filter(|value| value.is_finite() && *value > 0.0)
        .ok_or(CoreError::InvalidAnnotation)?;
    let turns = dictionary.get(SIGNATURE_ROTATION_KEY.as_bytes()).and_then(Object::as_i64).unwrap_or(0);
    let displayed_aspect = if turns % 2 == 0 { aspect } else { 1.0 / aspect.max(0.001) };
    let bounds = signature_bounds(rect.center(), displayed_aspect, size, &page_bounds);
    dictionary.set("Rect", vec![bounds.x0.into(), bounds.y0.into(), bounds.x1.into(), bounds.y1.into()]);
    touch(document, object)?;
    regenerate_appearance(document, object)
}

pub fn delete_annotation(document: &mut LoDocument, page_index: usize, id: AnnotationId) -> CoreResult<()> {
    let object = find_owned(document, page_index, id)?;
    let page = structure::page_id(document, page_index)?;
    let remaining: Vec<Object> = annotation_ids(document, page)
        .into_iter()
        .filter(|candidate| *candidate != object)
        .map(Object::Reference)
        .collect();
    structure::page_dictionary_mut(document, page)?.set("Annots", remaining);
    document.objects.remove(&object);
    Ok(())
}

/// Removes owned ink strokes that pass within `radius` of any eraser point.
pub fn erase_ink(document: &mut LoDocument, page_index: usize, eraser: &[(f32, f32)], radius: f32) -> CoreResult<usize> {
    let index = annotation_index(document);
    let Some(annotations) = index.get(page_index) else {
        return Err(CoreError::InvalidAnnotation);
    };
    let hits: Vec<AnnotationId> = annotations
        .iter()
        .filter(|info| info.kind == AnnotationKind::Ink && info.owned.is_some())
        .filter(|info| {
            info.ink.iter().any(|stroke| {
                stroke.windows(2).any(|segment| {
                    eraser.iter().any(|point| distance_to_segment(*point, segment[0], segment[1]) <= radius)
                }) || (stroke.len() == 1 && eraser.iter().any(|p| (p.0 - stroke[0].0).hypot(p.1 - stroke[0].1) <= radius))
            })
        })
        .filter_map(|info| info.owned)
        .collect();
    for id in &hits {
        delete_annotation(document, page_index, *id)?;
    }
    Ok(hits.len())
}

pub fn distance_to_segment(point: (f32, f32), a: (f32, f32), b: (f32, f32)) -> f32 {
    let (dx, dy) = (b.0 - a.0, b.1 - a.1);
    let length_squared = dx * dx + dy * dy;
    if length_squared <= f32::EPSILON {
        return (point.0 - a.0).hypot(point.1 - a.1);
    }
    let t = (((point.0 - a.0) * dx + (point.1 - a.1) * dy) / length_squared).clamp(0.0, 1.0);
    (point.0 - (a.0 + t * dx)).hypot(point.1 - (a.1 + t * dy))
}

// MARK: Appearance

/// Rebuilds `/AP /N` from the annotation's own geometry and style.
pub fn regenerate_appearance(document: &mut LoDocument, object: ObjectId) -> CoreResult<()> {
    let dictionary = document.get_object(object).and_then(Object::as_dict).map_err(|_| CoreError::InvalidAnnotation)?.clone();
    let rect = current_rect(document, object)?;
    let color = color_of(document, &dictionary).unwrap_or(palette::BLACK);
    let width = border_width(&dictionary).unwrap_or(1.0);
    let quads = quads(&dictionary);
    let ink = ink_list(document, &dictionary);
    let stamp_title = dictionary
        .get(b"Name")
        .and_then(Object::as_name)
        .ok()
        .and_then(|name| StampPreset::from_pdf_name(&String::from_utf8_lossy(name)))
        .map(StampPreset::title)
        .unwrap_or("Stamp");
    let image = signature_image_data(&dictionary);
    let embedded = match &image {
        Some(data) => Some(appearance::embed_image(document, data).ok_or(CoreError::InvalidImage)?.0),
        None => None,
    };
    let line = number_array(document, dictionary.get(b"L").unwrap_or(&Object::Null)).filter(|values| values.len() == 4);
    let kind = classify(document, &dictionary);
    let appearance = match (kind, embedded) {
        (AnnotationKind::Highlight, _) => Appearance::Markup { style: MarkupStyle::Highlight, quads: &quads, color },
        (AnnotationKind::Underline, _) => Appearance::Markup { style: MarkupStyle::Underline, quads: &quads, color },
        (AnnotationKind::Strikethrough, _) => Appearance::Markup { style: MarkupStyle::StrikeOut, quads: &quads, color },
        (AnnotationKind::Ink, _) => Appearance::Ink { strokes: &ink, color, width },
        (AnnotationKind::Rectangle, _) => Appearance::Rectangle { color, width },
        (AnnotationKind::Oval, _) => Appearance::Oval { color, width },
        (AnnotationKind::Line | AnnotationKind::Arrow, _) => {
            let values = line.ok_or(CoreError::InvalidAnnotation)?;
            Appearance::Line {
                start: (values[0], values[1]),
                end: (values[2], values[3]),
                arrow: kind == AnnotationKind::Arrow,
                color,
                width,
            }
        }
        (AnnotationKind::TextNote, _) => Appearance::Note { color },
        (AnnotationKind::Stamp | AnnotationKind::Signature, Some(image)) => Appearance::Image {
            image,
            quarter_turns: dictionary.get(SIGNATURE_ROTATION_KEY.as_bytes()).and_then(Object::as_i64).unwrap_or(0),
        },
        (AnnotationKind::Stamp, None) => Appearance::Stamp { title: stamp_title, color },
        _ => return Ok(()),
    };
    let form = appearance::build(document, &rect, &appearance);
    let dictionary = dictionary_mut(document, object)?;
    dictionary.set("AP", dictionary! { "N" => form });
    Ok(())
}
