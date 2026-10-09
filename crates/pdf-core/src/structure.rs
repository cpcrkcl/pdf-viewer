//! Object-level page tree operations on `lopdf` documents.
//!
//! Every page is normalized to be a direct child of the root `/Pages` node
//! with its inheritable attributes materialized. That keeps reorder, delete
//! and insert simple and avoids silently changing a page's resources or boxes.

use std::collections::BTreeMap;

use lopdf::{Dictionary, Document, Object, ObjectId};

use crate::error::{CoreError, CoreResult};

const INHERITABLE_KEYS: [&[u8]; 4] = [b"Resources", b"MediaBox", b"CropBox", b"Rotate"];

pub fn parse(bytes: &[u8]) -> CoreResult<Document> {
    let document = Document::load_mem(bytes).map_err(|_| CoreError::InvalidPdf)?;
    if document.is_encrypted() {
        return Err(CoreError::PasswordRequired);
    }
    Ok(document)
}

pub fn serialize(document: &mut Document) -> CoreResult<Vec<u8>> {
    let mut bytes = Vec::new();
    document
        .save_to(&mut bytes)
        .map_err(|_| CoreError::CouldNotCopyDocument)?;
    if bytes.is_empty() {
        return Err(CoreError::CouldNotCopyDocument);
    }
    Ok(bytes)
}

pub fn root_pages_id(document: &Document) -> CoreResult<ObjectId> {
    document
        .catalog()
        .and_then(|catalog| catalog.get(b"Pages"))
        .and_then(Object::as_reference)
        .map_err(|_| CoreError::InvalidPdf)
}

/// Page object ids in document order.
pub fn page_ids(document: &Document) -> Vec<ObjectId> {
    document.get_pages().into_values().collect()
}

pub fn page_count(document: &Document) -> usize {
    document.get_pages().len()
}

pub fn page_id(document: &Document, index: usize) -> CoreResult<ObjectId> {
    page_ids(document)
        .get(index)
        .copied()
        .ok_or(CoreError::InvalidPageSelection)
}

pub fn page_dictionary_mut(document: &mut Document, page: ObjectId) -> CoreResult<&mut Dictionary> {
    document
        .get_object_mut(page)
        .and_then(Object::as_dict_mut)
        .map_err(|_| CoreError::CouldNotCopyPage)
}

pub fn page_dictionary(document: &Document, page: ObjectId) -> CoreResult<&Dictionary> {
    document
        .get_object(page)
        .and_then(Object::as_dict)
        .map_err(|_| CoreError::CouldNotCopyPage)
}

/// Copies inherited attributes onto every page, then makes every page a
/// direct child of the root page tree node in its current order.
pub fn flatten_page_tree(document: &mut Document) -> CoreResult<()> {
    let pages = page_ids(document);
    for page in &pages {
        materialize_inherited_attributes(document, *page)?;
    }
    set_page_order(document, &pages)
}

fn materialize_inherited_attributes(document: &mut Document, page: ObjectId) -> CoreResult<()> {
    let mut inherited: BTreeMap<Vec<u8>, Object> = BTreeMap::new();
    let mut current = page_dictionary(document, page)?
        .get(b"Parent")
        .and_then(Object::as_reference)
        .ok();
    let mut depth = 0;
    while let Some(parent) = current {
        depth += 1;
        if depth > 64 {
            return Err(CoreError::InvalidPdf);
        }
        let Ok(dictionary) = document.get_object(parent).and_then(Object::as_dict) else {
            break;
        };
        for key in INHERITABLE_KEYS {
            if !inherited.contains_key(key)
                && let Ok(value) = dictionary.get(key)
            {
                inherited.insert(key.to_vec(), value.clone());
            }
        }
        current = dictionary.get(b"Parent").and_then(Object::as_reference).ok();
    }
    let dictionary = page_dictionary_mut(document, page)?;
    for (key, value) in inherited {
        if !dictionary.has(&key) {
            dictionary.set(key, value);
        }
    }
    if !dictionary.has(b"MediaBox") {
        dictionary.set("MediaBox", vec![0.into(), 0.into(), 612.into(), 792.into()]);
    }
    Ok(())
}

/// Rewrites the root `/Pages` node to contain exactly `pages`, in order.
/// Intermediate page tree nodes become unreachable and are pruned on save.
pub fn set_page_order(document: &mut Document, pages: &[ObjectId]) -> CoreResult<()> {
    if pages.is_empty() {
        return Err(CoreError::CannotDeleteOnlyPage);
    }
    let root = root_pages_id(document)?;
    for page in pages {
        page_dictionary_mut(document, *page)?.set("Parent", Object::Reference(root));
    }
    let root_dictionary = document
        .get_object_mut(root)
        .and_then(Object::as_dict_mut)
        .map_err(|_| CoreError::InvalidPdf)?;
    root_dictionary.set(
        "Kids",
        pages.iter().copied().map(Object::Reference).collect::<Vec<_>>(),
    );
    root_dictionary.set("Count", pages.len() as i64);
    for key in INHERITABLE_KEYS {
        root_dictionary.remove(key);
    }
    Ok(())
}

pub fn rotation(document: &Document, page: ObjectId) -> i64 {
    page_dictionary(document, page)
        .ok()
        .and_then(|dictionary| dictionary.get(b"Rotate").ok())
        .and_then(|value| value.as_i64().ok())
        .map(normalized_rotation)
        .unwrap_or(0)
}

pub fn normalized_rotation(rotation: i64) -> i64 {
    rotation.rem_euclid(360) / 90 * 90
}

pub fn set_rotation(document: &mut Document, page: ObjectId, rotation: i64) -> CoreResult<()> {
    page_dictionary_mut(document, page)?.set("Rotate", normalized_rotation(rotation));
    Ok(())
}

/// The page's crop box (falling back to its media box) as `[x0, y0, x1, y1]`.
pub fn crop_box(document: &Document, page: ObjectId) -> [f32; 4] {
    let dictionary = page_dictionary(document, page).ok();
    let read = |key: &[u8]| -> Option<[f32; 4]> {
        let array = dictionary?.get(key).ok()?;
        let array = match array {
            Object::Reference(id) => document.get_object(*id).ok()?.as_array().ok()?,
            other => other.as_array().ok()?,
        };
        if array.len() != 4 {
            return None;
        }
        let mut values = [0f32; 4];
        for (slot, value) in values.iter_mut().zip(array) {
            *slot = value.as_float().ok()?;
        }
        Some([
            values[0].min(values[2]),
            values[1].min(values[3]),
            values[0].max(values[2]),
            values[1].max(values[3]),
        ])
    };
    read(b"CropBox")
        .or_else(|| read(b"MediaBox"))
        .unwrap_or([0.0, 0.0, 612.0, 792.0])
}

/// Imports the listed pages of `source` into `destination` at `index`,
/// renumbering source objects so they never collide. Returns the new page ids.
pub fn import_pages(
    destination: &mut Document,
    mut source: Document,
    source_indexes: &[usize],
    index: usize,
) -> CoreResult<Vec<ObjectId>> {
    flatten_page_tree(&mut source)?;
    let source_pages = page_ids(&source);
    let selected: Vec<ObjectId> = source_indexes
        .iter()
        .map(|source_index| {
            source_pages
                .get(*source_index)
                .copied()
                .ok_or(CoreError::InvalidPageSelection)
        })
        .collect::<CoreResult<_>>()?;

    // Only form fields with a widget on an imported page come along. The list
    // is parked on the source page tree root so renumbering rewrites it.
    let imported_fields = root_fields_for_pages(&source, &selected);
    let source_catalog = source
        .trailer
        .get(b"Root")
        .and_then(Object::as_reference)
        .map_err(|_| CoreError::InvalidPdf)?;
    if let Ok(catalog) = source.get_object_mut(source_catalog).and_then(Object::as_dict_mut) {
        catalog.remove(b"AcroForm");
        catalog.remove(b"Outlines");
        catalog.remove(b"Names");
        catalog.remove(b"StructTreeRoot");
    }
    let source_root_pages = root_pages_id(&source)?;
    {
        let root = source
            .get_object_mut(source_root_pages)
            .and_then(Object::as_dict_mut)
            .map_err(|_| CoreError::InvalidPdf)?;
        root.set(
            "Kids",
            selected.iter().copied().map(Object::Reference).collect::<Vec<_>>(),
        );
        root.set(
            IMPORTED_FIELDS_KEY,
            imported_fields.into_iter().map(Object::Reference).collect::<Vec<_>>(),
        );
    }
    source.prune_objects();
    source.renumber_objects_with(destination.max_id + 1);

    let source_root = root_pages_id(&source)?;
    let source_catalog = source
        .trailer
        .get(b"Root")
        .and_then(Object::as_reference)
        .ok();
    let renumbered_pages = page_ids_from_kids(&source)?;
    if renumbered_pages.len() != selected.len() {
        return Err(CoreError::CouldNotCopyPage);
    }
    let imported_fields = source
        .get_object(source_root)
        .and_then(Object::as_dict)
        .and_then(|root| root.get(IMPORTED_FIELDS_KEY.as_bytes()))
        .and_then(Object::as_array)
        .cloned()
        .unwrap_or_default();

    for (id, object) in std::mem::take(&mut source.objects) {
        if Some(id) == source_catalog || id == source_root {
            continue;
        }
        destination.objects.insert(id, object);
    }
    destination.max_id = destination.max_id.max(source.max_id);

    let mut order = page_ids(destination);
    if index > order.len() {
        return Err(CoreError::InvalidInsertionIndex);
    }
    for (offset, page) in renumbered_pages.iter().enumerate() {
        order.insert(index + offset, *page);
    }
    set_page_order(destination, &order)?;

    append_acroform_fields(destination, imported_fields)?;
    Ok(renumbered_pages)
}

fn page_ids_from_kids(document: &Document) -> CoreResult<Vec<ObjectId>> {
    let root = root_pages_id(document)?;
    document
        .get_object(root)
        .and_then(Object::as_dict)
        .and_then(|dictionary| dictionary.get(b"Kids"))
        .and_then(Object::as_array)
        .map_err(|_| CoreError::InvalidPdf)?
        .iter()
        .map(|kid| kid.as_reference().map_err(|_| CoreError::InvalidPdf))
        .collect()
}

const IMPORTED_FIELDS_KEY: &str = "PDFViewerImportedFields";

/// Top-level AcroForm field ids that own a widget on any of `pages`.
fn root_fields_for_pages(document: &Document, pages: &[ObjectId]) -> Vec<ObjectId> {
    let mut roots = Vec::new();
    for page in pages {
        let annotation_ids: Vec<ObjectId> = page_dictionary(document, *page)
            .ok()
            .and_then(|dictionary| dictionary.get(b"Annots").ok())
            .and_then(|annots| match annots {
                Object::Reference(id) => document.get_object(*id).ok()?.as_array().ok(),
                other => other.as_array().ok(),
            })
            .map(|array| array.iter().filter_map(|item| item.as_reference().ok()).collect())
            .unwrap_or_default();
        for annotation in annotation_ids {
            let Ok(dictionary) = document.get_object(annotation).and_then(Object::as_dict) else {
                continue;
            };
            if dictionary.get(b"Subtype").and_then(Object::as_name).ok() != Some(b"Widget") {
                continue;
            }
            let mut field = annotation;
            for _ in 0..64 {
                match document
                    .get_object(field)
                    .and_then(Object::as_dict)
                    .and_then(|dictionary| dictionary.get(b"Parent"))
                    .and_then(Object::as_reference)
                {
                    Ok(parent) => field = parent,
                    Err(_) => break,
                }
            }
            if !roots.contains(&field) {
                roots.push(field);
            }
        }
    }
    roots
}

fn append_acroform_fields(document: &mut Document, fields: Vec<Object>) -> CoreResult<()> {
    if fields.is_empty() {
        return Ok(());
    }
    let catalog_id = document
        .trailer
        .get(b"Root")
        .and_then(Object::as_reference)
        .map_err(|_| CoreError::InvalidPdf)?;
    let existing = document
        .get_object(catalog_id)
        .and_then(Object::as_dict)
        .ok()
        .and_then(|catalog| catalog.get(b"AcroForm").ok().cloned());
    let acro_form_id = match existing {
        Some(Object::Reference(id)) => id,
        Some(Object::Dictionary(dictionary)) => document.add_object(dictionary),
        _ => document.add_object(Dictionary::from_iter([(
            "Fields",
            Object::Array(Vec::new()),
        )])),
    };
    document
        .get_object_mut(catalog_id)
        .and_then(Object::as_dict_mut)
        .map_err(|_| CoreError::InvalidPdf)?
        .set("AcroForm", Object::Reference(acro_form_id));

    let existing_fields = document
        .get_object(acro_form_id)
        .and_then(Object::as_dict)
        .ok()
        .and_then(|dictionary| dictionary.get(b"Fields").ok().cloned());
    let mut merged = match existing_fields {
        Some(Object::Array(array)) => array,
        Some(Object::Reference(id)) => document
            .get_object(id)
            .and_then(Object::as_array)
            .cloned()
            .unwrap_or_default(),
        _ => Vec::new(),
    };
    merged.extend(fields);
    document
        .get_object_mut(acro_form_id)
        .and_then(Object::as_dict_mut)
        .map_err(|_| CoreError::InvalidPdf)?
        .set("Fields", merged);
    Ok(())
}
