//! Deterministic PDF fixtures for tests across the workspace.

use lopdf::content::{Content, Operation};
use lopdf::{Dictionary, Document as LoDocument, Object, Stream, StringFormat, dictionary};

use crate::loader::AccessPermissions;
use crate::security;
use crate::structure;

/// One US-Letter page per entry, each drawing its text in Helvetica 24pt.
pub fn text_pdf(pages: &[&str]) -> Vec<u8> {
    build(pages, false)
}

/// `count` pages labelled "Page 1" … "Page N".
pub fn numbered_pdf(count: usize) -> Vec<u8> {
    let labels: Vec<String> = (1..=count).map(|n| format!("Page {n}")).collect();
    let refs: Vec<&str> = labels.iter().map(String::as_str).collect();
    text_pdf(&refs)
}

/// Like [`text_pdf`] with a flat outline entry pointing at every page.
pub fn outlined_pdf(pages: &[&str]) -> Vec<u8> {
    build(pages, true)
}

pub fn protected_pdf(pages: &[&str], user_password: &str, owner_password: &str, permissions: u32) -> Vec<u8> {
    let mut document = structure::parse(&text_pdf(pages)).expect("fixture parses");
    security::encrypt(&mut document, user_password, owner_password, AccessPermissions(permissions))
        .expect("fixture encrypts");
    structure::serialize(&mut document).expect("fixture saves")
}

fn build(pages: &[&str], outline: bool) -> Vec<u8> {
    let mut document = LoDocument::with_version("1.7");
    let pages_id = document.new_object_id();
    let font_id = document.add_object(dictionary! {
        "Type" => "Font",
        "Subtype" => "Type1",
        "BaseFont" => "Helvetica",
        "Encoding" => "WinAnsiEncoding",
    });
    let resources_id = document.add_object(dictionary! {
        "Font" => dictionary! { "F1" => font_id },
    });
    let mut kids = Vec::new();
    for text in pages {
        let content = Content {
            operations: vec![
                Operation::new("BT", vec![]),
                Operation::new("Tf", vec!["F1".into(), 24.into()]),
                Operation::new("Td", vec![72.into(), 680.into()]),
                Operation::new("Tj", vec![Object::String(text.as_bytes().to_vec(), StringFormat::Literal)]),
                Operation::new("ET", vec![]),
            ],
        };
        let content_id = document.add_object(Stream::new(Dictionary::new(), content.encode().expect("content encodes")));
        let page_id = document.add_object(dictionary! {
            "Type" => "Page",
            "Parent" => pages_id,
            "Contents" => content_id,
            "Resources" => resources_id,
            "MediaBox" => vec![0.into(), 0.into(), 612.into(), 792.into()],
        });
        kids.push(Object::Reference(page_id));
    }
    let count = kids.len() as i64;
    document.objects.insert(
        pages_id,
        Object::Dictionary(dictionary! { "Type" => "Pages", "Kids" => kids.clone(), "Count" => count }),
    );
    let mut catalog = dictionary! { "Type" => "Catalog", "Pages" => pages_id };
    if outline && !kids.is_empty() {
        let outlines_id = document.new_object_id();
        let item_ids: Vec<_> = (0..kids.len()).map(|_| document.new_object_id()).collect();
        for (index, (item_id, page)) in item_ids.iter().zip(&kids).enumerate() {
            let mut item = dictionary! {
                "Title" => Object::string_literal(format!("Section {}", index + 1)),
                "Parent" => outlines_id,
                "Dest" => vec![page.clone(), "Fit".into()],
            };
            if index > 0 {
                item.set("Prev", item_ids[index - 1]);
            }
            if let Some(next) = item_ids.get(index + 1) {
                item.set("Next", *next);
            }
            document.objects.insert(*item_id, Object::Dictionary(item));
        }
        document.objects.insert(
            outlines_id,
            Object::Dictionary(dictionary! {
                "Type" => "Outlines",
                "First" => item_ids[0],
                "Last" => *item_ids.last().unwrap(),
                "Count" => item_ids.len() as i64,
            }),
        );
        catalog.set("Outlines", outlines_id);
    }
    let catalog_id = document.add_object(catalog);
    document.trailer.set("Root", catalog_id);
    let mut bytes = Vec::new();
    document.save_to(&mut bytes).expect("fixture saves");
    bytes
}

/// One page whose content is a single noisy RGB image (Flate-compressed), for
/// compression tests.
pub fn image_pdf(width: u32, height: u32) -> Vec<u8> {
    let mut pixels = Vec::with_capacity((width * height * 3) as usize);
    let mut seed: u32 = 0x1234_5678;
    for y in 0..height {
        for x in 0..width {
            seed = seed.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
            let noise = (seed >> 24) as u8 / 8;
            pixels.extend_from_slice(&[
                ((x * 255) / width) as u8 ^ noise,
                ((y * 255) / height) as u8 ^ noise,
                128u8.wrapping_add(noise),
            ]);
        }
    }
    let mut document = LoDocument::with_version("1.7");
    let pages_id = document.new_object_id();
    let mut image = Stream::new(
        dictionary! {
            "Type" => "XObject",
            "Subtype" => "Image",
            "Width" => i64::from(width),
            "Height" => i64::from(height),
            "ColorSpace" => "DeviceRGB",
            "BitsPerComponent" => 8,
        },
        pixels,
    );
    image.compress().expect("image compresses");
    let image_id = document.add_object(image);
    let content = format!("q {} 0 0 {} 0 0 cm /Im1 Do Q", width as f32 * 0.5, height as f32 * 0.5);
    let content_id = document.add_object(Stream::new(Dictionary::new(), content.into_bytes()));
    let page_id = document.add_object(dictionary! {
        "Type" => "Page",
        "Parent" => pages_id,
        "Contents" => content_id,
        "Resources" => dictionary! { "XObject" => dictionary! { "Im1" => image_id } },
        "MediaBox" => vec![0.into(), 0.into(), (width as f32 * 0.5).into(), (height as f32 * 0.5).into()],
    });
    document.objects.insert(
        pages_id,
        Object::Dictionary(dictionary! { "Type" => "Pages", "Kids" => vec![page_id.into()], "Count" => 1 }),
    );
    let catalog_id = document.add_object(dictionary! { "Type" => "Catalog", "Pages" => pages_id });
    document.trailer.set("Root", catalog_id);
    let mut bytes = Vec::new();
    document.save_to(&mut bytes).expect("fixture saves");
    bytes
}

/// A page carrying one annotation PDFViewer did not create.
pub fn third_party_annotated_pdf() -> Vec<u8> {
    let mut document = structure::parse(&text_pdf(&["Annotated"])).expect("fixture parses");
    let page = structure::page_id(&document, 0).expect("page");
    let annotation = document.add_object(dictionary! {
        "Type" => "Annot",
        "Subtype" => "Square",
        "Rect" => vec![100.into(), 100.into(), 200.into(), 200.into()],
        "C" => vec![0.into(), 0.into(), 1.into()],
        "NM" => Object::string_literal("someone-else"),
    });
    structure::page_dictionary_mut(&mut document, page)
        .expect("page dictionary")
        .set("Annots", vec![Object::Reference(annotation)]);
    structure::serialize(&mut document).expect("fixture saves")
}

/// A small opaque PNG for signature and stamp tests.
pub fn signature_png(width: u32, height: u32) -> Vec<u8> {
    let mut image = image::RgbaImage::new(width, height);
    for (x, y, pixel) in image.enumerate_pixels_mut() {
        let on_line = (y as i64 - (height as i64 / 2)).abs() < 3 || (x as i64 - y as i64 * width as i64 / height as i64).abs() < 3;
        *pixel = if on_line { image::Rgba([10, 20, 120, 255]) } else { image::Rgba([0, 0, 0, 0]) };
    }
    let mut bytes = Vec::new();
    image::DynamicImage::ImageRgba8(image)
        .write_to(&mut std::io::Cursor::new(&mut bytes), image::ImageFormat::Png)
        .expect("png encodes");
    bytes
}

/// Two pages with text, checkbox, radio, combo and read-only fields.
pub fn form_pdf() -> Vec<u8> {
    let mut document = structure::parse(&text_pdf(&["Form page one", "Form page two"])).expect("fixture parses");
    let pages = structure::page_ids(&document);
    let state = |document: &mut LoDocument, on: &str| {
        let on_stream = document.add_object(Stream::new(dictionary! { "Type" => "XObject", "Subtype" => "Form", "BBox" => vec![0.into(), 0.into(), 12.into(), 12.into()] }, b"0 g 2 2 8 8 re f".to_vec()));
        let off_stream = document.add_object(Stream::new(dictionary! { "Type" => "XObject", "Subtype" => "Form", "BBox" => vec![0.into(), 0.into(), 12.into(), 12.into()] }, Vec::new()));
        let mut normal = Dictionary::new();
        normal.set(on, on_stream);
        normal.set("Off", off_stream);
        dictionary! { "N" => normal }
    };
    let rect = |x: i64, y: i64, w: i64, h: i64| vec![x.into(), y.into(), (x + w).into(), (y + h).into()];

    let name = document.add_object(dictionary! {
        "Type" => "Annot", "Subtype" => "Widget", "FT" => "Tx", "T" => Object::string_literal("name"),
        "TU" => Object::string_literal("Full Name"), "Ff" => 2, "MaxLen" => 10,
        "DV" => Object::string_literal("Ada"), "V" => Object::string_literal(""),
        "DA" => Object::string_literal("/Helv 0 Tf 0 g"),
        "Rect" => rect(72, 600, 200, 20), "P" => pages[0],
    });
    let agree_ap = state(&mut document, "Yes");
    let agree = document.add_object(dictionary! {
        "Type" => "Annot", "Subtype" => "Widget", "FT" => "Btn", "T" => Object::string_literal("agree"),
        "V" => "Off", "AS" => "Off", "DV" => "Off", "AP" => agree_ap, "Rect" => rect(72, 560, 12, 12), "P" => pages[0],
    });
    let radio_parent = document.new_object_id();
    let red_ap = state(&mut document, "red");
    let red = document.add_object(dictionary! {
        "Type" => "Annot", "Subtype" => "Widget", "Parent" => radio_parent, "AS" => "Off", "AP" => red_ap,
        "Rect" => rect(72, 520, 12, 12), "P" => pages[0],
    });
    let blue_ap = state(&mut document, "blue");
    let blue = document.add_object(dictionary! {
        "Type" => "Annot", "Subtype" => "Widget", "Parent" => radio_parent, "AS" => "Off", "AP" => blue_ap,
        "Rect" => rect(100, 520, 12, 12), "P" => pages[0],
    });
    document.objects.insert(radio_parent, Object::Dictionary(dictionary! {
        "FT" => "Btn", "T" => Object::string_literal("color"), "Ff" => 1 << 15, "V" => "Off", "DV" => "blue",
        "Kids" => vec![red.into(), blue.into()],
    }));
    let size = document.add_object(dictionary! {
        "Type" => "Annot", "Subtype" => "Widget", "FT" => "Ch", "T" => Object::string_literal("size"), "Ff" => 1 << 17,
        "Opt" => vec![Object::string_literal("S"), Object::string_literal("M"), Object::string_literal("L")],
        "V" => Object::string_literal("M"), "DV" => Object::string_literal("M"),
        "Rect" => rect(72, 480, 80, 20), "P" => pages[0],
    });
    let locked = document.add_object(dictionary! {
        "Type" => "Annot", "Subtype" => "Widget", "FT" => "Tx", "T" => Object::string_literal("locked"), "Ff" => 1,
        "V" => Object::string_literal("fixed"), "Rect" => rect(72, 600, 200, 20), "P" => pages[1],
    });
    structure::page_dictionary_mut(&mut document, pages[0]).unwrap().set(
        "Annots",
        vec![name.into(), agree.into(), red.into(), blue.into(), size.into()],
    );
    structure::page_dictionary_mut(&mut document, pages[1]).unwrap().set("Annots", vec![locked.into()]);
    let helv = document.add_object(dictionary! { "Type" => "Font", "Subtype" => "Type1", "BaseFont" => "Helvetica" });
    let acro_form = document.add_object(dictionary! {
        "Fields" => vec![name.into(), agree.into(), radio_parent.into(), size.into(), locked.into()],
        "DA" => Object::string_literal("/Helv 0 Tf 0 g"),
        "DR" => dictionary! { "Font" => dictionary! { "Helv" => helv } },
    });
    let catalog = document.trailer.get(b"Root").and_then(Object::as_reference).unwrap();
    document.get_object_mut(catalog).and_then(Object::as_dict_mut).unwrap().set("AcroForm", acro_form);
    structure::serialize(&mut document).expect("fixture saves")
}
