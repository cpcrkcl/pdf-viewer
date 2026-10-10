//! Appearance streams for annotations PDFViewer creates.
//!
//! Every owned annotation carries a normal appearance (`/AP /N`) so it looks
//! the same in PDFium, Preview and Acrobat. Appearances are drawn directly in
//! page space: the form's `/BBox` equals the annotation `/Rect` and its
//! matrix is the identity.

use std::fmt::Write as _;

use lopdf::{Dictionary, Document as LoDocument, Object, ObjectId, Stream, dictionary};

use crate::geometry::PdfBox;

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Rgba {
    pub r: f32,
    pub g: f32,
    pub b: f32,
    pub a: f32,
}

impl Rgba {
    pub const fn new(r: f32, g: f32, b: f32, a: f32) -> Self {
        Self { r, g, b, a }
    }

    pub fn with_alpha(self, a: f32) -> Self {
        Self { a, ..self }
    }

    pub fn to_pdf_array(self) -> Vec<Object> {
        vec![self.r.into(), self.g.into(), self.b.into()]
    }

    fn rg(self) -> String {
        format!("{:.4} {:.4} {:.4} rg", self.r, self.g, self.b)
    }

    fn rg_stroke(self) -> String {
        format!("{:.4} {:.4} {:.4} RG", self.r, self.g, self.b)
    }
}

/// What to draw; built from the annotation dictionary by `annotations`.
pub enum Appearance<'a> {
    Markup {
        style: MarkupStyle,
        quads: &'a [PdfBox],
        color: Rgba,
    },
    Ink {
        strokes: &'a [Vec<(f32, f32)>],
        color: Rgba,
        width: f32,
    },
    Rectangle {
        color: Rgba,
        width: f32,
    },
    Oval {
        color: Rgba,
        width: f32,
    },
    Line {
        start: (f32, f32),
        end: (f32, f32),
        arrow: bool,
        color: Rgba,
        width: f32,
    },
    Note {
        color: Rgba,
    },
    Stamp {
        title: &'a str,
        color: Rgba,
    },
    Image {
        image: ObjectId,
        quarter_turns: i64,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MarkupStyle {
    Highlight,
    Underline,
    StrikeOut,
}

/// Builds the appearance form XObject and returns its id.
pub fn build(document: &mut LoDocument, rect: &PdfBox, appearance: &Appearance) -> ObjectId {
    let mut content = String::new();
    let mut resources = Dictionary::new();
    let mut graphics_states = Dictionary::new();
    let mut set_opacity = |content: &mut String, alpha: f32, multiply: bool| {
        if alpha >= 0.999 && !multiply {
            return;
        }
        let name = format!("GS{}", graphics_states.len());
        let mut state = dictionary! { "Type" => "ExtGState", "CA" => alpha, "ca" => alpha };
        if multiply {
            state.set("BM", "Multiply");
        }
        graphics_states.set(name.clone(), state);
        let _ = writeln!(content, "/{name} gs");
    };

    match appearance {
        Appearance::Markup { style, quads, color } => {
            set_opacity(&mut content, color.a, *style == MarkupStyle::Highlight);
            match style {
                MarkupStyle::Highlight => {
                    let _ = writeln!(content, "{}", color.rg());
                    for quad in *quads {
                        let _ = writeln!(content, "{} re f", rect_operands(quad));
                    }
                }
                MarkupStyle::Underline | MarkupStyle::StrikeOut => {
                    let _ = writeln!(content, "{} 1 J", color.rg_stroke());
                    for quad in *quads {
                        let thickness = (quad.height() / 14.0).max(0.75);
                        let y = if *style == MarkupStyle::Underline {
                            quad.y0 + thickness * 1.5
                        } else {
                            quad.y0 + quad.height() * 0.42
                        };
                        let _ = writeln!(content, "{thickness:.3} w {:.3} {y:.3} m {:.3} {y:.3} l S", quad.x0, quad.x1);
                    }
                }
            }
        }
        Appearance::Ink { strokes, color, width } => {
            set_opacity(&mut content, color.a, false);
            let _ = writeln!(content, "{} {width:.3} w 1 J 1 j", color.rg_stroke());
            for stroke in *strokes {
                let mut points = stroke.iter();
                if let Some((x, y)) = points.next() {
                    let _ = write!(content, "{x:.3} {y:.3} m ");
                    if stroke.len() == 1 {
                        let _ = write!(content, "{x:.3} {y:.3} l ");
                    }
                    for (x, y) in points {
                        let _ = write!(content, "{x:.3} {y:.3} l ");
                    }
                    let _ = writeln!(content, "S");
                }
            }
        }
        Appearance::Rectangle { color, width } => {
            set_opacity(&mut content, color.a, false);
            let inner = rect.inset(width / 2.0, width / 2.0);
            let _ = writeln!(content, "{} {width:.3} w {} re S", color.rg_stroke(), rect_operands(&inner));
        }
        Appearance::Oval { color, width } => {
            set_opacity(&mut content, color.a, false);
            let inner = rect.inset(width / 2.0, width / 2.0);
            let _ = writeln!(content, "{} {width:.3} w", color.rg_stroke());
            content.push_str(&ellipse_path(&inner));
            content.push_str("S\n");
        }
        Appearance::Line { start, end, arrow, color, width } => {
            set_opacity(&mut content, color.a, false);
            let _ = writeln!(content, "{} {} {width:.3} w 1 J 1 j", color.rg_stroke(), color.rg());
            let (dx, dy) = (end.0 - start.0, end.1 - start.1);
            let length = dx.hypot(dy).max(0.001);
            let (ux, uy) = (dx / length, dy / length);
            let head = (width * 4.0).max(8.0);
            // Stop the shaft at the arrowhead's base so the tip stays sharp.
            let shaft_end = if *arrow { (end.0 - ux * head * 0.8, end.1 - uy * head * 0.8) } else { *end };
            let _ = writeln!(
                content,
                "{:.3} {:.3} m {:.3} {:.3} l S",
                start.0, start.1, shaft_end.0, shaft_end.1
            );
            if *arrow {
                let base = (end.0 - ux * head, end.1 - uy * head);
                let (px, py) = (-uy * head * 0.5, ux * head * 0.5);
                let _ = writeln!(
                    content,
                    "{:.3} {:.3} m {:.3} {:.3} l {:.3} {:.3} l h f",
                    end.0,
                    end.1,
                    base.0 + px,
                    base.1 + py,
                    base.0 - px,
                    base.1 - py
                );
            }
        }
        Appearance::Note { color } => {
            let inner = rect.inset(1.0, 1.0);
            let _ = writeln!(content, "{} 0.25 0.25 0.25 RG 1 w", color.with_alpha(1.0).rg());
            content.push_str(&rounded_rect(&inner, 3.0));
            content.push_str("B\n0.2 0.2 0.2 RG 1.2 w\n");
            let left = inner.x0 + inner.width() * 0.22;
            let right = inner.x1 - inner.width() * 0.22;
            for fraction in [0.70, 0.50, 0.30] {
                let y = inner.y0 + inner.height() * fraction;
                let _ = writeln!(content, "{left:.3} {y:.3} m {right:.3} {y:.3} l S");
            }
        }
        Appearance::Stamp { title, color } => {
            let inner = rect.inset(2.0, 2.0);
            let _ = writeln!(content, "{} 2.5 w", color.rg_stroke());
            content.push_str(&rounded_rect(&inner, 6.0));
            content.push_str("S\n");
            let text = title.to_uppercase();
            let size = (inner.height() * 0.45).min(inner.width() / (text.chars().count().max(1) as f32 * 0.68));
            let text_width = helvetica_bold_width(&text) * size;
            let x = inner.x0 + (inner.width() - text_width) / 2.0;
            let y = inner.y0 + (inner.height() - size * 0.7) / 2.0;
            let _ = writeln!(
                content,
                "BT {} /StampFont {size:.3} Tf {x:.3} {y:.3} Td ({}) Tj ET",
                color.rg(),
                escape_literal(&text)
            );
            resources.set(
                "Font",
                dictionary! {
                    "StampFont" => dictionary! {
                        "Type" => "Font",
                        "Subtype" => "Type1",
                        "BaseFont" => "Helvetica-Bold",
                        "Encoding" => "WinAnsiEncoding",
                    },
                },
            );
        }
        Appearance::Image { image, quarter_turns } => {
            // Map the unit square onto the rect, rotating about its center.
            let (cx, cy) = rect.center();
            let turns = quarter_turns.rem_euclid(4);
            let (w, h) = if turns % 2 == 0 { (rect.width(), rect.height()) } else { (rect.height(), rect.width()) };
            let angle = -(turns as f32) * std::f32::consts::FRAC_PI_2;
            let (sin, cos) = angle.sin_cos();
            let _ = writeln!(
                content,
                "q {:.5} {:.5} {:.5} {:.5} {cx:.3} {cy:.3} cm {w:.3} 0 0 {h:.3} {:.3} {:.3} cm /Img Do Q",
                cos,
                sin,
                -sin,
                cos,
                -w / 2.0,
                -h / 2.0
            );
            resources.set("XObject", dictionary! { "Img" => *image });
        }
    }
    if !graphics_states.is_empty() {
        resources.set("ExtGState", graphics_states);
    }
    let form = Stream::new(
        dictionary! {
            "Type" => "XObject",
            "Subtype" => "Form",
            "FormType" => 1,
            "BBox" => vec![rect.x0.into(), rect.y0.into(), rect.x1.into(), rect.y1.into()],
            "Resources" => resources,
        },
        content.into_bytes(),
    );
    document.add_object(form)
}

fn rect_operands(rect: &PdfBox) -> String {
    format!("{:.3} {:.3} {:.3} {:.3}", rect.x0, rect.y0, rect.width(), rect.height())
}

fn ellipse_path(rect: &PdfBox) -> String {
    const K: f32 = 0.552_284_8;
    let (cx, cy) = rect.center();
    let (rx, ry) = (rect.width() / 2.0, rect.height() / 2.0);
    let (ox, oy) = (rx * K, ry * K);
    format!(
        "{:.3} {:.3} m {:.3} {:.3} {:.3} {:.3} {:.3} {:.3} c {:.3} {:.3} {:.3} {:.3} {:.3} {:.3} c {:.3} {:.3} {:.3} {:.3} {:.3} {:.3} c {:.3} {:.3} {:.3} {:.3} {:.3} {:.3} c h\n",
        cx + rx, cy,
        cx + rx, cy + oy, cx + ox, cy + ry, cx, cy + ry,
        cx - ox, cy + ry, cx - rx, cy + oy, cx - rx, cy,
        cx - rx, cy - oy, cx - ox, cy - ry, cx, cy - ry,
        cx + ox, cy - ry, cx + rx, cy - oy, cx + rx, cy,
    )
}

fn rounded_rect(rect: &PdfBox, radius: f32) -> String {
    const K: f32 = 0.552_284_8;
    let r = radius.min(rect.width() / 2.0).min(rect.height() / 2.0);
    let o = r * K;
    let (x0, y0, x1, y1) = (rect.x0, rect.y0, rect.x1, rect.y1);
    format!(
        "{:.3} {:.3} m {:.3} {:.3} l {:.3} {:.3} {:.3} {:.3} {:.3} {:.3} c {:.3} {:.3} l {:.3} {:.3} {:.3} {:.3} {:.3} {:.3} c {:.3} {:.3} l {:.3} {:.3} {:.3} {:.3} {:.3} {:.3} c {:.3} {:.3} l {:.3} {:.3} {:.3} {:.3} {:.3} {:.3} c h\n",
        x0 + r, y0,
        x1 - r, y0,
        x1 - r + o, y0, x1, y0 + r - o, x1, y0 + r,
        x1, y1 - r,
        x1, y1 - r + o, x1 - r + o, y1, x1 - r, y1,
        x0 + r, y1,
        x0 + r - o, y1, x0, y1 - r + o, x0, y1 - r,
        x0, y0 + r,
        x0, y0 + r - o, x0 + r - o, y0, x0 + r, y0,
    )
}

/// Approximate Helvetica-Bold advance (em units) for centering stamp text.
fn helvetica_bold_width(text: &str) -> f32 {
    text.chars()
        .map(|c| match c {
            'I' | ' ' => 0.28,
            'J' => 0.556,
            'M' => 0.833,
            'W' => 0.944,
            'A' | 'B' | 'C' | 'D' | 'H' | 'K' | 'N' | 'R' | 'U' | 'V' | 'X' | 'Y' => 0.722,
            'E' | 'P' | 'S' => 0.667,
            'F' | 'T' | 'Z' => 0.611,
            'G' | 'O' | 'Q' => 0.778,
            'L' => 0.611,
            _ => 0.6,
        })
        .sum()
}

pub fn escape_literal(text: &str) -> String {
    let mut escaped = String::with_capacity(text.len());
    for c in text.chars() {
        match c {
            '(' | ')' | '\\' => {
                escaped.push('\\');
                escaped.push(c);
            }
            c if c.is_ascii() && !c.is_ascii_control() => escaped.push(c),
            _ => escaped.push('?'),
        }
    }
    escaped
}

/// Embeds a PNG or JPEG as an image XObject (with an alpha soft mask for
/// transparent PNGs). Returns the object id and the pixel size.
pub fn embed_image(document: &mut LoDocument, bytes: &[u8]) -> Option<(ObjectId, u32, u32)> {
    let format = image::guess_format(bytes).ok()?;
    let decoded = image::load_from_memory_with_format(bytes, format).ok()?;
    let (width, height) = (decoded.width(), decoded.height());
    if width == 0 || height == 0 {
        return None;
    }
    if format == image::ImageFormat::Jpeg && matches!(decoded.color(), image::ColorType::Rgb8 | image::ColorType::L8) {
        let gray = decoded.color() == image::ColorType::L8;
        let stream = Stream::new(
            dictionary! {
                "Type" => "XObject",
                "Subtype" => "Image",
                "Width" => i64::from(width),
                "Height" => i64::from(height),
                "ColorSpace" => if gray { "DeviceGray" } else { "DeviceRGB" },
                "BitsPerComponent" => 8,
                "Filter" => "DCTDecode",
            },
            bytes.to_vec(),
        )
        .with_compression(false);
        return Some((document.add_object(stream), width, height));
    }
    let rgba = decoded.to_rgba8();
    let mut rgb = Vec::with_capacity((width * height * 3) as usize);
    let mut alpha = Vec::with_capacity((width * height) as usize);
    for pixel in rgba.pixels() {
        rgb.extend_from_slice(&pixel.0[..3]);
        alpha.push(pixel.0[3]);
    }
    let mut image = Stream::new(
        dictionary! {
            "Type" => "XObject",
            "Subtype" => "Image",
            "Width" => i64::from(width),
            "Height" => i64::from(height),
            "ColorSpace" => "DeviceRGB",
            "BitsPerComponent" => 8,
        },
        rgb,
    );
    if alpha.iter().any(|value| *value != 255) {
        let mut mask = Stream::new(
            dictionary! {
                "Type" => "XObject",
                "Subtype" => "Image",
                "Width" => i64::from(width),
                "Height" => i64::from(height),
                "ColorSpace" => "DeviceGray",
                "BitsPerComponent" => 8,
            },
            alpha,
        );
        let _ = mask.compress();
        let mask_id = document.add_object(mask);
        image.dict.set("SMask", mask_id);
    }
    let _ = image.compress();
    Some((document.add_object(image), width, height))
}
