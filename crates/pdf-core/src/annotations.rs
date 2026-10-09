//! Reading and writing page annotations at the object level.

use lopdf::{Document as LoDocument, Object, ObjectId};

use crate::structure;

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
        Object::String(bytes, _) => Some(lopdf::decode_text_string(value).unwrap_or_else(|_| {
            String::from_utf8_lossy(bytes).into_owned()
        })),
        Object::Name(name) => Some(String::from_utf8_lossy(name).into_owned()),
        _ => None,
    }
}

/// A normalized `[x0, y0, x1, y1]` rectangle.
pub fn rect_value(document: &LoDocument, value: &Object) -> Option<[f32; 4]> {
    let array = match value {
        Object::Reference(id) => document.get_object(*id).ok()?.as_array().ok()?,
        other => other.as_array().ok()?,
    };
    if array.len() != 4 {
        return None;
    }
    let mut values = [0f32; 4];
    for (slot, item) in values.iter_mut().zip(array) {
        *slot = match item {
            Object::Reference(id) => document.get_object(*id).ok()?.as_float().ok()?,
            other => other.as_float().ok()?,
        };
    }
    Some([
        values[0].min(values[2]),
        values[1].min(values[3]),
        values[0].max(values[2]),
        values[1].max(values[3]),
    ])
}
