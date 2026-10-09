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
