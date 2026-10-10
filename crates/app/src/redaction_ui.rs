//! Marking and applying permanent redactions.

use egui::{Color32, CornerRadius, CursorIcon, Painter, Rect, RichText, Stroke, StrokeKind, Ui};
use pdf_core::geometry::PdfBox;
use pdf_core::redaction::{MAXIMUM_REGIONS, RedactionRegion};

use crate::document_tab::{DocumentTab, Tool};
use crate::reader_view::ReaderResponse;
use crate::theme;

#[derive(Default)]
pub struct RedactionState {
    pub regions: Vec<RedactionRegion>,
    pub reason_label: String,
    drag: Option<(usize, (f32, f32), (f32, f32))>,
}

pub enum RedactionRequest {
    None,
    Error(String),
    ConfirmApply,
}

fn mark(tab: &mut DocumentTab, region: RedactionRegion) {
    if tab.redaction.regions.len() < MAXIMUM_REGIONS {
        tab.redaction.regions.push(region);
    }
}

pub fn handle(ctx: &egui::Context, tab: &mut DocumentTab, response: &ReaderResponse) {
    if tab.tool != Tool::Redact {
        tab.redaction.drag = None;
        return;
    }
    if response.hover.is_some() {
        ctx.set_cursor_icon(CursorIcon::Crosshair);
    }
    if let Some(start) = response.drag_start {
        tab.redaction.drag = Some((start.page, start.point, start.point));
    }
    if let Some(current) = response.drag_current
        && let Some((page, _, end)) = tab.redaction.drag.as_mut()
        && *page == current.page
    {
        *end = current.point;
    }
    if response.drag_stopped
        && let Some((page, start, end)) = tab.redaction.drag.take()
    {
        let rect = PdfBox::from_points(start, end);
        if rect.width() >= 2.0 && rect.height() >= 2.0 {
            mark(tab, RedactionRegion { page, rect });
        }
    }
}

pub fn paint(painter: &Painter, tab: &DocumentTab, response: &ReaderResponse) {
    let draw = |rect: Rect| {
        painter.rect_filled(rect, CornerRadius::ZERO, Color32::from_black_alpha(150));
        painter.rect_stroke(rect, CornerRadius::ZERO, Stroke::new(1.5, theme::colors().danger), StrokeKind::Outside);
    };
    for region in &tab.redaction.regions {
        if let Some(view) = response.page(region.page) {
            draw(view.box_to_screen(&region.rect));
        }
    }
    if let Some((page, start, end)) = tab.redaction.drag
        && let Some(view) = response.page(page)
    {
        draw(view.box_to_screen(&PdfBox::from_points(start, end)));
    }
}

pub fn toolbar(ui: &mut Ui, tab: &mut DocumentTab) -> RedactionRequest {
    let mut request = RedactionRequest::None;
    ui.horizontal_wrapped(|ui| {
        ui.label(RichText::new("Redact").strong().color(theme::colors().danger));
        ui.weak("Drag over content to mark it.");
        ui.separator();
        let count = tab.redaction.regions.len();
        ui.label(format!("{count} area{}", if count == 1 { "" } else { "s" }));
        if ui.add_enabled(count > 0, egui::Button::new("Undo Area")).clicked() {
            tab.redaction.regions.pop();
        }
        if ui.add_enabled(count > 0, egui::Button::new("Clear")).clicked() {
            tab.redaction.regions.clear();
        }
        let marked = tab.search.marked.len();
        if ui
            .add_enabled(marked > 0, egui::Button::new(format!("Add {marked} Marked Search Match{}", if marked == 1 { "" } else { "es" })))
            .on_hover_text("Tick matches in the Search sidebar to redact them")
            .clicked()
        {
            let regions: Vec<RedactionRegion> = tab
                .search
                .marked
                .iter()
                .filter_map(|index| tab.search.matches().get(*index))
                .flat_map(|found| found.boxes.iter().map(|rect| RedactionRegion { page: found.page, rect: rect.inset(-1.0, -1.0) }))
                .collect();
            for region in regions {
                mark(tab, region);
            }
            tab.search.marked.clear();
        }
        ui.separator();
        ui.label("Reason label");
        ui.add(egui::TextEdit::singleline(&mut tab.redaction.reason_label).hint_text("Optional, e.g. Privileged").char_limit(80).desired_width(150.0));
        ui.separator();
        if ui.add_enabled(count > 0, theme::destructive("Apply Redactions…")).clicked() {
            request = if tab.session.security.allows_document_changes() {
                RedactionRequest::ConfirmApply
            } else {
                RedactionRequest::Error("This PDF's permissions don't allow changing its content.".into())
            };
        }
        if ui.button("Done").clicked() {
            tab.tool = Tool::SelectText;
        }
    });
    request
}

/// Burns the marked regions into the working copy as one undoable revision.
pub fn apply(tab: &mut DocumentTab) -> Result<usize, String> {
    let regions = std::mem::take(&mut tab.redaction.regions);
    let label = pdf_core::redaction::sanitized_reason_label(&tab.redaction.reason_label);
    let result = pdf_core::redaction::redact(&tab.pdf_data(), &regions, label.as_deref())
        .and_then(|bytes| tab.session.editor.apply_processed_document(bytes, None));
    match result {
        Ok(()) => {
            let pages: std::collections::BTreeSet<usize> = regions.iter().map(|region| region.page).collect();
            tab.after_mutation(None);
            tab.tool = Tool::SelectText;
            Ok(pages.len())
        }
        Err(error) => {
            tab.redaction.regions = regions;
            Err(error.to_string())
        }
    }
}
