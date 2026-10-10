//! AcroForm text, checkbox, radio and choice fields.
//!
//! Fields are discovered through the widgets on each page (in page order),
//! so only fields a user can actually see are offered. XFA is not supported.

use std::collections::HashMap;
use std::fmt::Write as _;

use lopdf::{Dictionary, Document as LoDocument, Object, ObjectId, Stream, dictionary};
use thiserror::Error;

use crate::annotations::{annotation_ids, rect_value, text_value};
use crate::appearance::escape_literal;
use crate::engine;
use crate::error::{CoreError, CoreResult};
use crate::geometry::PdfBox;
use crate::structure;

const READ_ONLY: i64 = 1 << 0;
const REQUIRED: i64 = 1 << 1;
const RADIO: i64 = 1 << 15;
const PUSH_BUTTON: i64 = 1 << 16;
const COMBO: i64 = 1 << 17;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FieldKind {
    Text,
    Checkbox,
    Radio,
    Choice,
    Signature,
    Unsupported,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FieldValue {
    Text(String),
    Checked(bool),
    Choice(Option<String>),
    Radio(Option<String>),
}

#[derive(Debug, Clone, PartialEq)]
pub struct FormField {
    pub name: String,
    pub alternate_name: Option<String>,
    pub page: usize,
    pub rect: PdfBox,
    pub kind: FieldKind,
    pub value: Option<FieldValue>,
    pub default_value: Option<String>,
    pub options: Vec<String>,
    pub is_required: bool,
    pub is_read_only: bool,
    pub maximum_length: Option<usize>,
    pub is_combo: bool,
}

impl FormField {
    pub fn display_name(&self) -> &str {
        self.alternate_name
            .as_deref()
            .map(str::trim)
            .filter(|name| !name.is_empty())
            .unwrap_or(&self.name)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum FormError {
    #[error("The form field “{0}” is no longer available.")]
    FieldNotFound(String),
    #[error("The form field “{0}” is read-only.")]
    FieldReadOnly(String),
    #[error("The selected value is not valid for the form field “{0}”.")]
    IncompatibleValue(String),
    #[error("The form field “{field}” accepts at most {maximum} characters.")]
    ValueTooLong { field: String, maximum: usize },
    #[error("Choose one of the available values for “{0}”.")]
    InvalidChoice(String),
    #[error("Complete the required form fields: {}.", .0.join(", "))]
    RequiredFieldsMissing(Vec<String>),
    #[error("PDFViewer could not create a safe flattened copy of this form.")]
    CouldNotFlatten,
}

impl From<FormError> for CoreError {
    fn from(error: FormError) -> Self {
        CoreError::Form(error.to_string())
    }
}

struct Widget {
    page: usize,
    object: ObjectId,
    field: ObjectId,
}

fn dictionary(document: &LoDocument, id: ObjectId) -> Option<&Dictionary> {
    document.get_object(id).ok()?.as_dict().ok()
}

/// Walks up `/Parent` from a widget to its terminal field (the first
/// ancestor-or-self with a `/T`), building the dotted full name.
fn field_of(document: &LoDocument, widget: ObjectId) -> Option<(ObjectId, String)> {
    let mut current = widget;
    let mut terminal = None;
    let mut names = Vec::new();
    for _ in 0..64 {
        let node = dictionary(document, current)?;
        if let Some(name) = node.get(b"T").ok().and_then(|value| text_value(document, value)) {
            if terminal.is_none() {
                terminal = Some(current);
            }
            names.push(name);
        }
        match node.get(b"Parent").and_then(Object::as_reference) {
            Ok(parent) => current = parent,
            Err(_) => break,
        }
    }
    names.reverse();
    let name = names.join(".").trim().to_owned();
    (!name.is_empty()).then(|| (terminal.unwrap_or(widget), name))
}

/// An inheritable field attribute, searched from the widget upward.
fn inherited<'a>(document: &'a LoDocument, start: ObjectId, key: &[u8]) -> Option<&'a Object> {
    let mut current = start;
    for _ in 0..64 {
        let node = dictionary(document, current)?;
        if let Ok(value) = node.get(key) {
            return Some(match value {
                Object::Reference(id) => document.get_object(*id).ok()?,
                other => other,
            });
        }
        current = node.get(b"Parent").and_then(Object::as_reference).ok()?;
    }
    None
}

fn widgets(document: &LoDocument) -> Vec<(String, Vec<Widget>)> {
    let mut order: Vec<String> = Vec::new();
    let mut grouped: HashMap<String, Vec<Widget>> = HashMap::new();
    for (page_index, page) in structure::page_ids(document).into_iter().enumerate() {
        for object in annotation_ids(document, page) {
            let Some(annotation) = dictionary(document, object) else { continue };
            if annotation.get(b"Subtype").and_then(Object::as_name).ok() != Some(b"Widget") {
                continue;
            }
            let Some((field, name)) = field_of(document, object) else { continue };
            if !grouped.contains_key(&name) {
                order.push(name.clone());
            }
            grouped.entry(name).or_default().push(Widget {
                page: page_index,
                object,
                field,
            });
        }
    }
    order
        .into_iter()
        .filter_map(|name| grouped.remove(&name).map(|widgets| (name, widgets)))
        .collect()
}

fn flags(document: &LoDocument, widget: ObjectId) -> i64 {
    inherited(document, widget, b"Ff").and_then(|value| value.as_i64().ok()).unwrap_or(0)
}

fn kind_of(document: &LoDocument, widget: ObjectId) -> FieldKind {
    let field_type = inherited(document, widget, b"FT").and_then(|value| value.as_name().ok());
    match field_type {
        Some(b"Tx") => FieldKind::Text,
        Some(b"Ch") => FieldKind::Choice,
        Some(b"Sig") => FieldKind::Signature,
        Some(b"Btn") => {
            let flags = flags(document, widget);
            if flags & PUSH_BUTTON != 0 {
                FieldKind::Unsupported
            } else if flags & RADIO != 0 {
                FieldKind::Radio
            } else {
                FieldKind::Checkbox
            }
        }
        _ => FieldKind::Unsupported,
    }
}

/// The widget's "on" appearance state name (anything other than `Off`).
fn on_state(document: &LoDocument, widget: ObjectId) -> Option<String> {
    let appearance = dictionary(document, widget)?.get(b"AP").ok()?;
    let appearance = match appearance {
        Object::Reference(id) => dictionary(document, *id)?,
        Object::Dictionary(dictionary) => dictionary,
        _ => return None,
    };
    let normal = match appearance.get(b"N").ok()? {
        Object::Reference(id) => dictionary(document, *id)?,
        Object::Dictionary(dictionary) => dictionary,
        _ => return None,
    };
    normal
        .iter()
        .map(|(key, _)| String::from_utf8_lossy(key).into_owned())
        .find(|key| key != "Off")
}

fn appearance_state(document: &LoDocument, widget: ObjectId) -> Option<String> {
    dictionary(document, widget)?
        .get(b"AS")
        .and_then(Object::as_name)
        .ok()
        .map(|name| String::from_utf8_lossy(name).into_owned())
}

fn string_value(document: &LoDocument, value: Option<&Object>) -> Option<String> {
    match value? {
        Object::Array(items) => items.first().and_then(|item| text_value(document, item)),
        other => text_value(document, other),
    }
}

fn choice_options(document: &LoDocument, widget: ObjectId) -> Vec<String> {
    let Some(Object::Array(options)) = inherited(document, widget, b"Opt") else {
        return Vec::new();
    };
    options
        .iter()
        .filter_map(|option| match option {
            Object::Array(pair) if pair.len() == 2 => text_value(document, &pair[1]),
            Object::Reference(id) => match document.get_object(*id).ok()? {
                Object::Array(pair) if pair.len() == 2 => text_value(document, &pair[1]),
                other => text_value(document, other),
            },
            other => text_value(document, other),
        })
        .collect()
}

fn make_field(document: &LoDocument, name: &str, widgets: &[Widget]) -> FormField {
    let first = widgets[0].object;
    let kind = kind_of(document, first);
    let flags = flags(document, first);
    let mut options = match kind {
        FieldKind::Choice => widgets.iter().flat_map(|w| choice_options(document, w.object)).collect(),
        FieldKind::Radio => widgets.iter().filter_map(|w| on_state(document, w.object)).collect(),
        _ => Vec::new(),
    };
    let mut seen = std::collections::HashSet::new();
    options.retain(|option: &String| !option.is_empty() && seen.insert(option.clone()));
    let value = match kind {
        FieldKind::Text => Some(FieldValue::Text(
            string_value(document, inherited(document, first, b"V")).unwrap_or_default(),
        )),
        FieldKind::Checkbox => Some(FieldValue::Checked(widgets.iter().any(|widget| {
            appearance_state(document, widget.object).is_some_and(|state| state != "Off")
        }))),
        FieldKind::Choice => Some(FieldValue::Choice(
            string_value(document, inherited(document, first, b"V")).filter(|value| !value.is_empty()),
        )),
        FieldKind::Radio => Some(FieldValue::Radio(widgets.iter().find_map(|widget| {
            appearance_state(document, widget.object).filter(|state| state != "Off")
        }))),
        FieldKind::Signature | FieldKind::Unsupported => None,
    };
    let rect = dictionary(document, first)
        .and_then(|widget| widget.get(b"Rect").ok())
        .and_then(|rect| rect_value(document, rect))
        .map(PdfBox::from_array)
        .unwrap_or_default();
    FormField {
        name: name.to_owned(),
        alternate_name: dictionary(document, widgets[0].field)
            .and_then(|field| field.get(b"TU").ok())
            .and_then(|value| text_value(document, value)),
        page: widgets[0].page,
        rect,
        kind,
        value,
        default_value: string_value(document, inherited(document, first, b"DV")),
        options,
        is_required: widgets.iter().any(|w| self::flags(document, w.object) & REQUIRED != 0),
        is_read_only: widgets.iter().any(|w| self::flags(document, w.object) & READ_ONLY != 0),
        maximum_length: widgets
            .iter()
            .filter_map(|w| inherited(document, w.object, b"MaxLen").and_then(|v| v.as_i64().ok()))
            .filter(|length| *length > 0)
            .map(|length| length as usize)
            .min(),
        is_combo: flags & COMBO != 0,
    }
}

pub fn fields(document: &LoDocument) -> Vec<FormField> {
    widgets(document)
        .iter()
        .map(|(name, widgets)| make_field(document, name, widgets))
        .collect()
}

pub fn set_value(document: &mut LoDocument, name: &str, value: &FieldValue) -> CoreResult<()> {
    let grouped = widgets(document);
    let (_, widgets) = grouped
        .iter()
        .find(|(candidate, _)| candidate == name)
        .ok_or_else(|| FormError::FieldNotFound(name.to_owned()))?;
    let field = make_field(document, name, widgets);
    if field.is_read_only {
        return Err(FormError::FieldReadOnly(name.to_owned()).into());
    }
    let field_object = widgets[0].field;
    match (field.kind, value) {
        (FieldKind::Text, FieldValue::Text(text)) => {
            if let Some(maximum) = field.maximum_length
                && text.chars().count() > maximum
            {
                return Err(FormError::ValueTooLong { field: name.to_owned(), maximum }.into());
            }
            set_text(document, field_object, widgets, text)?;
        }
        (FieldKind::Choice, FieldValue::Choice(choice)) => {
            if let Some(choice) = choice
                && !field.options.contains(choice)
            {
                return Err(FormError::InvalidChoice(name.to_owned()).into());
            }
            set_text(document, field_object, widgets, choice.as_deref().unwrap_or(""))?;
        }
        (FieldKind::Checkbox, FieldValue::Checked(checked)) => {
            let mut chosen = None;
            for widget in widgets {
                let state = if *checked { on_state(document, widget.object).unwrap_or_else(|| "Yes".into()) } else { "Off".into() };
                chosen.get_or_insert(state.clone());
                widget_mut(document, widget.object)?.set("AS", Object::Name(state.into_bytes()));
            }
            let state = chosen.unwrap_or_else(|| "Off".into());
            field_mut(document, field_object)?.set("V", Object::Name(state.into_bytes()));
        }
        (FieldKind::Radio, FieldValue::Radio(selection)) => {
            if let Some(selection) = selection
                && !field.options.contains(selection)
            {
                return Err(FormError::InvalidChoice(name.to_owned()).into());
            }
            set_radio(document, field_object, widgets, selection.as_deref())?;
        }
        _ => return Err(FormError::IncompatibleValue(name.to_owned()).into()),
    }
    mark_need_appearances(document);
    Ok(())
}

fn widget_mut(document: &mut LoDocument, id: ObjectId) -> CoreResult<&mut Dictionary> {
    document.get_object_mut(id).and_then(Object::as_dict_mut).map_err(|_| CoreError::InvalidPdf)
}

fn field_mut(document: &mut LoDocument, id: ObjectId) -> CoreResult<&mut Dictionary> {
    widget_mut(document, id)
}

fn set_radio(document: &mut LoDocument, field: ObjectId, widgets: &[Widget], selection: Option<&str>) -> CoreResult<()> {
    for widget in widgets {
        let on = on_state(document, widget.object);
        let state = match (&on, selection) {
            (Some(on), Some(selection)) if on == selection => on.clone(),
            _ => "Off".to_owned(),
        };
        widget_mut(document, widget.object)?.set("AS", Object::Name(state.into_bytes()));
    }
    field_mut(document, field)?.set(
        "V",
        Object::Name(selection.unwrap_or("Off").as_bytes().to_vec()),
    );
    Ok(())
}

fn set_text(document: &mut LoDocument, field: ObjectId, widgets: &[Widget], text: &str) -> CoreResult<()> {
    field_mut(document, field)?.set("V", lopdf::text_string(text));
    for widget in widgets {
        regenerate_text_appearance(document, widget.object, text)?;
    }
    Ok(())
}

pub fn reset(document: &mut LoDocument) -> CoreResult<()> {
    for (name, widgets) in widgets(document) {
        let field = make_field(document, &name, &widgets);
        if field.is_read_only {
            continue;
        }
        let field_object = widgets[0].field;
        match field.kind {
            FieldKind::Text | FieldKind::Choice => {
                let default = field.default_value.clone().unwrap_or_default();
                set_text(document, field_object, &widgets, &default)?;
            }
            FieldKind::Checkbox => {
                let checked = field
                    .default_value
                    .as_deref()
                    .is_some_and(|value| !value.is_empty() && !value.eq_ignore_ascii_case("Off"));
                set_value(document, &name, &FieldValue::Checked(checked))?;
            }
            FieldKind::Radio => {
                let default = field.default_value.clone().filter(|value| field.options.contains(value));
                set_radio(document, field_object, &widgets, default.as_deref())?;
            }
            FieldKind::Signature | FieldKind::Unsupported => {}
        }
    }
    mark_need_appearances(document);
    Ok(())
}

pub fn validate_required(document: &LoDocument) -> Result<(), FormError> {
    let missing: Vec<String> = fields(document)
        .into_iter()
        .filter(|field| field.is_required)
        .filter(|field| match &field.value {
            Some(FieldValue::Text(value)) => value.trim().is_empty(),
            Some(FieldValue::Checked(value)) => !value,
            Some(FieldValue::Choice(value) | FieldValue::Radio(value)) => {
                value.as_deref().is_none_or(|value| value.trim().is_empty())
            }
            None => true,
        })
        .map(|field| field.display_name().to_owned())
        .collect();
    if missing.is_empty() { Ok(()) } else { Err(FormError::RequiredFieldsMissing(missing)) }
}

/// Field name → value, for exporting interactive values as JSON.
pub fn values_json(document: &LoDocument) -> serde_json::Value {
    let mut map = serde_json::Map::new();
    for field in fields(document) {
        let value = match field.value {
            Some(FieldValue::Text(text)) => serde_json::Value::String(text),
            Some(FieldValue::Checked(checked)) => serde_json::Value::Bool(checked),
            Some(FieldValue::Choice(choice) | FieldValue::Radio(choice)) => {
                choice.map(serde_json::Value::String).unwrap_or(serde_json::Value::Null)
            }
            None => continue,
        };
        map.insert(field.name, value);
    }
    serde_json::Value::Object(map)
}

fn mark_need_appearances(document: &mut LoDocument) {
    let Ok(catalog) = document.trailer.get(b"Root").and_then(Object::as_reference) else { return };
    let acro_form = document
        .get_object(catalog)
        .and_then(Object::as_dict)
        .and_then(|catalog| catalog.get(b"AcroForm"))
        .cloned();
    let target = match acro_form {
        Ok(Object::Reference(id)) => document.get_object_mut(id).and_then(Object::as_dict_mut).ok(),
        Ok(Object::Dictionary(_)) => document
            .get_object_mut(catalog)
            .and_then(Object::as_dict_mut)
            .and_then(|catalog| catalog.get_mut(b"AcroForm"))
            .and_then(Object::as_dict_mut)
            .ok(),
        _ => None,
    };
    if let Some(acro_form) = target {
        acro_form.set("NeedAppearances", true);
    }
}

/// Draws the field's text with its `/DA` font and size so every viewer
/// shows the new value even without regenerating appearances.
fn regenerate_text_appearance(document: &mut LoDocument, widget: ObjectId, text: &str) -> CoreResult<()> {
    let rect = dictionary(document, widget)
        .and_then(|widget| widget.get(b"Rect").ok())
        .and_then(|rect| rect_value(document, rect))
        .map(PdfBox::from_array)
        .ok_or(CoreError::InvalidPdf)?;
    let default_appearance = inherited(document, widget, b"DA")
        .and_then(|value| text_value(document, value))
        .or_else(|| acro_form_default_appearance(document))
        .unwrap_or_else(|| "/Helv 0 Tf 0 g".to_owned());
    let (font_name, mut size, color) = parse_default_appearance(&default_appearance);
    let (width, height) = (rect.width(), rect.height());
    let multiline = flags(document, widget) & (1 << 12) != 0;
    if size <= 0.0 {
        size = if multiline { 10.0 } else { (height * 0.66).clamp(4.0, 12.0) };
    }
    let font = font_resource(document, &font_name);
    let mut content = String::from("/Tx BMC q 1 1 ");
    let _ = write!(content, "{:.3} {:.3} re W n BT /{font_name} {size:.3} Tf {color} ", width - 2.0, height - 2.0);
    let lines: Vec<&str> = if multiline { text.lines().collect() } else { vec![text.lines().next().unwrap_or("")] };
    let leading = size * 1.15;
    let first_y = if multiline { height - 2.0 - size } else { (height - size * 0.78) / 2.0 };
    let _ = write!(content, "2 {first_y:.3} Td {leading:.3} TL ");
    for (index, line) in lines.iter().enumerate() {
        if index > 0 {
            content.push_str("T* ");
        }
        let _ = write!(content, "({}) Tj ", escape_literal(line));
    }
    content.push_str("ET Q EMC");
    let form = Stream::new(
        dictionary! {
            "Type" => "XObject",
            "Subtype" => "Form",
            "BBox" => vec![0.into(), 0.into(), width.into(), height.into()],
            "Resources" => dictionary! { "Font" => dictionary! { font_name.clone() => font } },
        },
        content.into_bytes(),
    );
    let form = document.add_object(form);
    widget_mut(document, widget)?.set("AP", dictionary! { "N" => form });
    Ok(())
}

fn acro_form_default_appearance(document: &LoDocument) -> Option<String> {
    let catalog = document.catalog().ok()?;
    let acro_form = match catalog.get(b"AcroForm").ok()? {
        Object::Reference(id) => dictionary(document, *id)?,
        Object::Dictionary(dictionary) => dictionary,
        _ => return None,
    };
    acro_form.get(b"DA").ok().and_then(|value| text_value(document, value))
}

fn parse_default_appearance(da: &str) -> (String, f32, String) {
    let tokens: Vec<&str> = da.split_whitespace().collect();
    let mut font = "Helv".to_owned();
    let mut size = 0.0;
    let mut color = "0 g".to_owned();
    for (index, token) in tokens.iter().enumerate() {
        match *token {
            "Tf" if index >= 2 => {
                font = tokens[index - 2].trim_start_matches('/').to_owned();
                size = tokens[index - 1].parse().unwrap_or(0.0);
            }
            "g" if index >= 1 => color = format!("{} g", tokens[index - 1]),
            "rg" if index >= 3 => color = format!("{} {} {} rg", tokens[index - 3], tokens[index - 2], tokens[index - 1]),
            _ => {}
        }
    }
    (font, size, color)
}

/// The named font from `/AcroForm /DR`, or a Helvetica fallback.
fn font_resource(document: &LoDocument, name: &str) -> Object {
    let from_resources = document.catalog().ok().and_then(|catalog| {
        let acro_form = match catalog.get(b"AcroForm").ok()? {
            Object::Reference(id) => dictionary(document, *id)?,
            Object::Dictionary(dictionary) => dictionary,
            _ => return None,
        };
        let resources = match acro_form.get(b"DR").ok()? {
            Object::Reference(id) => dictionary(document, *id)?,
            Object::Dictionary(dictionary) => dictionary,
            _ => return None,
        };
        let fonts = match resources.get(b"Font").ok()? {
            Object::Reference(id) => dictionary(document, *id)?,
            Object::Dictionary(dictionary) => dictionary,
            _ => return None,
        };
        fonts.get(name.as_bytes()).ok().cloned()
    });
    from_resources.unwrap_or_else(|| {
        Object::Dictionary(dictionary! {
            "Type" => "Font",
            "Subtype" => "Type1",
            "BaseFont" => "Helvetica",
            "Encoding" => "WinAnsiEncoding",
        })
    })
}

/// A sharing copy with every annotation and widget burned into page content
/// and the interactive form removed. Required fields must be complete.
pub fn flattened(bytes: &[u8]) -> CoreResult<Vec<u8>> {
    let mut document = structure::parse(bytes)?;
    validate_required(&document)?;
    let page_count = structure::page_count(&document);
    for page in structure::page_ids(&document) {
        flatten_page(&mut document, page).map_err(|_| FormError::CouldNotFlatten)?;
    }
    if let Ok(catalog) = document.trailer.get(b"Root").and_then(Object::as_reference)
        && let Ok(catalog) = document.get_object_mut(catalog).and_then(Object::as_dict_mut)
    {
        catalog.remove(b"AcroForm");
    }
    document.prune_objects();
    let output = structure::serialize(&mut document)?;
    let check = structure::parse(&output)?;
    if structure::page_count(&check) != page_count || !fields(&check).is_empty() {
        return Err(FormError::CouldNotFlatten.into());
    }
    engine::load_nonempty(output.clone(), None).map_err(|_| FormError::CouldNotFlatten)?;
    Ok(output)
}

/// Draws every visible annotation appearance on `page` into its content and
/// removes those annotations. Links (and anything without an appearance)
/// stay interactive.
pub fn flatten_page(document: &mut LoDocument, page: ObjectId) -> CoreResult<()> {
    const HIDDEN: i64 = 1 << 1;
    const NO_VIEW: i64 = 1 << 5;
    let mut operations = String::new();
    let mut xobjects: Vec<(String, ObjectId)> = Vec::new();
    let mut kept = Vec::new();
    for (index, object) in annotation_ids(document, page).into_iter().enumerate() {
        let Some(annotation) = dictionary(document, object) else { continue };
        let subtype = annotation.get(b"Subtype").and_then(Object::as_name).unwrap_or(b"");
        if matches!(subtype, b"Link" | b"Popup") {
            kept.push(Object::Reference(object));
            continue;
        }
        let flags = annotation.get(b"F").and_then(Object::as_i64).unwrap_or(0);
        if flags & (HIDDEN | NO_VIEW) != 0 {
            continue;
        }
        let Some(appearance) = normal_appearance(document, annotation) else { continue };
        let Some(rect) = annotation.get(b"Rect").ok().and_then(|rect| rect_value(document, rect)).map(PdfBox::from_array) else {
            continue;
        };
        let Some(matrix) = appearance_to_rect(document, appearance, &rect) else { continue };
        let name = format!("PDFViewerFlat{index}");
        let _ = writeln!(
            operations,
            "q {:.5} {:.5} {:.5} {:.5} {:.5} {:.5} cm /{name} Do Q",
            matrix[0], matrix[1], matrix[2], matrix[3], matrix[4], matrix[5]
        );
        xobjects.push((name, appearance));
    }
    let page_dictionary = structure::page_dictionary(document, page)?;
    let mut resources = match page_dictionary.get(b"Resources") {
        Ok(Object::Reference(id)) => dictionary(document, *id).cloned().unwrap_or_default(),
        Ok(Object::Dictionary(resources)) => resources.clone(),
        _ => Dictionary::new(),
    };
    let mut xobject_dictionary = match resources.get(b"XObject") {
        Ok(Object::Reference(id)) => dictionary(document, *id).cloned().unwrap_or_default(),
        Ok(Object::Dictionary(existing)) => existing.clone(),
        _ => Dictionary::new(),
    };
    for (name, object) in &xobjects {
        xobject_dictionary.set(name.clone(), *object);
    }
    if !xobjects.is_empty() {
        resources.set("XObject", xobject_dictionary);
        let existing = match page_dictionary.get(b"Contents") {
            Ok(Object::Array(items)) => items.clone(),
            Ok(other) => vec![other.clone()],
            Err(_) => Vec::new(),
        };
        let open = document.add_object(Stream::new(Dictionary::new(), b"q\n".to_vec()));
        let close = document.add_object(Stream::new(Dictionary::new(), format!("Q\n{operations}").into_bytes()));
        let mut contents = vec![Object::Reference(open)];
        contents.extend(existing);
        contents.push(Object::Reference(close));
        let page_dictionary = structure::page_dictionary_mut(document, page)?;
        page_dictionary.set("Contents", contents);
        page_dictionary.set("Resources", resources);
    }
    let page_dictionary = structure::page_dictionary_mut(document, page)?;
    if kept.is_empty() {
        page_dictionary.remove(b"Annots");
    } else {
        page_dictionary.set("Annots", kept);
    }
    Ok(())
}

/// The `/AP /N` stream, choosing the `/AS` state for state dictionaries.
fn normal_appearance(document: &LoDocument, annotation: &Dictionary) -> Option<ObjectId> {
    let appearance = match annotation.get(b"AP").ok()? {
        Object::Reference(id) => dictionary(document, *id)?,
        Object::Dictionary(dictionary) => dictionary,
        _ => return None,
    };
    match appearance.get(b"N").ok()? {
        Object::Reference(id) => match document.get_object(*id).ok()? {
            Object::Stream(_) => Some(*id),
            Object::Dictionary(states) => {
                let state = annotation.get(b"AS").and_then(Object::as_name).ok()?;
                states.get(state).and_then(Object::as_reference).ok()
            }
            _ => None,
        },
        Object::Dictionary(states) => {
            let state = annotation.get(b"AS").and_then(Object::as_name).ok()?;
            states.get(state).and_then(Object::as_reference).ok()
        }
        _ => None,
    }
}

/// PDF 32000-1 §12.5.5: the matrix mapping the appearance's transformed
/// bounding box onto the annotation rectangle.
fn appearance_to_rect(document: &LoDocument, appearance: ObjectId, rect: &PdfBox) -> Option<[f32; 6]> {
    let Object::Stream(stream) = document.get_object(appearance).ok()? else { return None };
    let numbers = |key: &[u8]| -> Option<Vec<f32>> {
        stream.dict.get(key).ok()?.as_array().ok()?.iter().map(|value| value.as_float().ok()).collect()
    };
    let bbox = numbers(b"BBox").filter(|values| values.len() == 4)?;
    let matrix = numbers(b"Matrix").filter(|values| values.len() == 6).unwrap_or(vec![1.0, 0.0, 0.0, 1.0, 0.0, 0.0]);
    let corners = [(bbox[0], bbox[1]), (bbox[2], bbox[1]), (bbox[0], bbox[3]), (bbox[2], bbox[3])]
        .map(|(x, y)| (matrix[0] * x + matrix[2] * y + matrix[4], matrix[1] * x + matrix[3] * y + matrix[5]));
    let (min_x, max_x) = corners.iter().fold((f32::MAX, f32::MIN), |(lo, hi), (x, _)| (lo.min(*x), hi.max(*x)));
    let (min_y, max_y) = corners.iter().fold((f32::MAX, f32::MIN), |(lo, hi), (_, y)| (lo.min(*y), hi.max(*y)));
    let (width, height) = (max_x - min_x, max_y - min_y);
    if width <= 0.0 || height <= 0.0 {
        return None;
    }
    let sx = rect.width() / width;
    let sy = rect.height() / height;
    Some([sx, 0.0, 0.0, sy, rect.x0 - min_x * sx, rect.y0 - min_y * sy])
}
