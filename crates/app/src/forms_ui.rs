//! The form panel: discover, fill, validate, reset, export and flatten.

use egui::{RichText, Ui};
use pdf_core::forms::{self, FieldKind, FieldValue, FormField};

use crate::document_tab::DocumentTab;
use crate::theme::mocha;

pub enum FormRequest {
    None,
    Error(String),
    Info(String),
    ExportValues(Vec<u8>),
    ExportFlattened(Vec<u8>),
}

#[derive(Default)]
pub struct FormPanelState {
    pub visible: bool,
    /// Text being edited, committed on Return or focus loss.
    drafts: std::collections::HashMap<String, String>,
    cache: Option<(u64, Vec<FormField>)>,
    pub focus: Option<String>,
}

impl DocumentTab {
    pub fn form_fields(&mut self) -> Vec<FormField> {
        let generation = self.generation();
        if let Some((cached, fields)) = &self.forms.cache
            && *cached == generation
        {
            return fields.clone();
        }
        let fields = self.session.editor.parse().map(|document| forms::fields(&document)).unwrap_or_default();
        self.forms.cache = Some((generation, fields.clone()));
        fields
    }

    fn set_field(&mut self, name: &str, value: FieldValue) -> Result<(), String> {
        if !self.session.security.allows_form_field_entry() {
            return Err("This PDF's permissions don't allow filling in form fields.".into());
        }
        self.session
            .editor
            .mutate(|document| forms::set_value(document, name, &value))
            .map_err(|error| error.to_string())?;
        self.after_annotation_change();
        Ok(())
    }
}

pub fn panel(ui: &mut Ui, tab: &mut DocumentTab) -> FormRequest {
    let mut request = FormRequest::None;
    let fields = tab.form_fields();
    ui.horizontal(|ui| {
        ui.heading("Form");
        ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
            if ui.small_button("✕").clicked() {
                tab.forms.visible = false;
            }
        });
    });
    if fields.is_empty() {
        ui.weak("This PDF has no fillable AcroForm fields. XFA forms aren't supported.");
        return request;
    }
    ui.horizontal_wrapped(|ui| {
        if ui.button("Validate").clicked() {
            match tab.session.editor.parse().map(|document| forms::validate_required(&document)) {
                Ok(Ok(())) => request = FormRequest::Info("All required fields are complete.".into()),
                Ok(Err(error)) => request = FormRequest::Error(error.to_string()),
                Err(error) => request = FormRequest::Error(error.to_string()),
            }
        }
        if ui.button("Reset").clicked() {
            match tab.session.editor.mutate(forms::reset) {
                Ok(()) => {
                    tab.forms.drafts.clear();
                    tab.after_annotation_change();
                }
                Err(error) => request = FormRequest::Error(error.to_string()),
            }
        }
        if ui.button("Export Values…").clicked()
            && let Ok(document) = tab.session.editor.parse()
        {
            let json = serde_json::to_vec_pretty(&forms::values_json(&document)).unwrap_or_default();
            request = FormRequest::ExportValues(json);
        }
        if ui.button("Export Flattened Copy…").clicked() {
            match forms::flattened(&tab.pdf_data()) {
                Ok(bytes) => request = FormRequest::ExportFlattened(bytes),
                Err(error) => request = FormRequest::Error(error.to_string()),
            }
        }
    });
    ui.separator();
    let focus = tab.forms.focus.take();
    egui::ScrollArea::vertical().id_salt(("form-fields", tab.id)).auto_shrink([false, false]).show(ui, |ui| {
        for field in &fields {
            ui.add_space(4.0);
            ui.horizontal(|ui| {
                let mut title = RichText::new(field.display_name()).strong();
                if focus.as_deref() == Some(field.name.as_str()) {
                    title = title.color(mocha::BLUE);
                }
                let label = ui.add(egui::Button::new(title).frame(false)).on_hover_text(format!("Page {}", field.page + 1));
                if label.clicked() {
                    tab.navigate_to(field.page);
                    tab.scroll_to_point = Some((field.page, field.rect.center()));
                    tab.scroll_to_page = None;
                }
                if field.is_required {
                    ui.colored_label(mocha::RED, "*");
                }
                if field.is_read_only {
                    ui.weak("read-only");
                }
            });
            if let Err(message) = field_editor(ui, tab, field, focus.as_deref() == Some(field.name.as_str())) {
                request = FormRequest::Error(message);
            }
        }
    });
    request
}

fn field_editor(ui: &mut Ui, tab: &mut DocumentTab, field: &FormField, focus: bool) -> Result<(), String> {
    let enabled = !field.is_read_only;
    match (&field.kind, &field.value) {
        (FieldKind::Text, Some(FieldValue::Text(value))) => {
            let draft = tab.forms.drafts.entry(field.name.clone()).or_insert_with(|| value.clone());
            let mut edit = egui::TextEdit::singleline(draft).desired_width(f32::INFINITY);
            if let Some(maximum) = field.maximum_length {
                edit = edit.char_limit(maximum);
            }
            let response = ui.add_enabled(enabled, edit);
            if focus {
                response.request_focus();
            }
            if response.lost_focus() && draft != value {
                let text = draft.clone();
                let result = tab.set_field(&field.name, FieldValue::Text(text));
                if result.is_err() {
                    tab.forms.drafts.remove(&field.name);
                }
                return result;
            }
            if !response.has_focus() && draft != value && !response.lost_focus() {
                *draft = value.clone();
            }
        }
        (FieldKind::Checkbox, Some(FieldValue::Checked(checked))) => {
            let mut value = *checked;
            if ui.add_enabled(enabled, egui::Checkbox::new(&mut value, "Checked")).changed() {
                return tab.set_field(&field.name, FieldValue::Checked(value));
            }
        }
        (FieldKind::Radio, Some(FieldValue::Radio(selection))) => {
            let mut choice = None;
            ui.horizontal_wrapped(|ui| {
                for option in &field.options {
                    if ui.add_enabled(enabled, egui::RadioButton::new(selection.as_ref() == Some(option), option)).clicked() {
                        choice = Some(option.clone());
                    }
                }
            });
            if let Some(option) = choice {
                return tab.set_field(&field.name, FieldValue::Radio(Some(option)));
            }
        }
        (FieldKind::Choice, Some(FieldValue::Choice(selection))) => {
            let mut choice: Option<Option<String>> = None;
            ui.add_enabled_ui(enabled, |ui| {
                egui::ComboBox::from_id_salt(("choice", &field.name))
                    .selected_text(selection.clone().unwrap_or_else(|| "None".into()))
                    .width(ui.available_width() - 8.0)
                    .show_ui(ui, |ui| {
                        if ui.selectable_label(selection.is_none(), "None").clicked() {
                            choice = Some(None);
                        }
                        for option in &field.options {
                            if ui.selectable_label(selection.as_ref() == Some(option), option).clicked() {
                                choice = Some(Some(option.clone()));
                            }
                        }
                    });
            });
            if let Some(choice) = choice {
                return tab.set_field(&field.name, FieldValue::Choice(choice));
            }
        }
        (FieldKind::Signature, _) => {
            ui.weak("Signature fields need certificate signing, which PDFViewer doesn't provide. Use a visual signature instead.");
        }
        _ => {
            ui.weak("This field type isn't supported.");
        }
    }
    Ok(())
}
