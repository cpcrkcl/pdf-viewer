//! Pointer interaction on pages and the overlays drawn above them.

use egui::{Color32, CornerRadius, CursorIcon, Painter, Stroke, StrokeKind};
use pdf_core::text::LinkTarget;

use crate::document_tab::{DocumentTab, TextSelection, Tool};
use crate::reader_view::ReaderResponse;
use crate::theme::mocha;

pub enum InteractionAction {
    None,
    ConfirmExternalLink(String),
    RejectedLink,
}

pub const SEARCH_HIGHLIGHT: Color32 = Color32::from_rgba_premultiplied(120, 105, 20, 90);
pub const SEARCH_ACTIVE: Color32 = Color32::from_rgba_premultiplied(170, 90, 20, 140);
pub const TEXT_SELECTION: Color32 = Color32::from_rgba_premultiplied(40, 70, 130, 90);

/// Text selection and link activation for the Select Text tool.
pub fn handle_select_text(ctx: &egui::Context, tab: &mut DocumentTab, response: &ReaderResponse) -> InteractionAction {
    if tab.tool != Tool::SelectText {
        return InteractionAction::None;
    }
    let link_at = |tab: &DocumentTab, page: usize, point: (f32, f32)| {
        tab.pages
            .get(page)
            .and_then(|info| info.links.iter().find(|link| link.rect.contains(point)).cloned())
    };
    if let Some(hover) = response.hover {
        if link_at(tab, hover.page, hover.point).is_some() {
            ctx.set_cursor_icon(CursorIcon::PointingHand);
        } else if tab.text_index(ctx).is_some_and(|text| {
            text.get(hover.page)
                .and_then(|page| page.char_at(hover.point))
                .is_some()
        }) {
            ctx.set_cursor_icon(CursorIcon::Text);
        }
    }

    if let Some(start) = response.drag_start {
        tab.selection = None;
        if let Some(text) = tab.text_index(ctx)
            && let Some(index) = text.get(start.page).and_then(|page| page.char_at(start.point))
        {
            tab.selection = Some(TextSelection {
                page: start.page,
                anchor: index,
                focus: index,
            });
        }
    }
    if let Some(current) = response.drag_current
        && let Some(text) = tab.text_index(ctx)
        && let Some(selection) = tab.selection.as_mut()
        && selection.page == current.page
        && let Some(index) = text.get(current.page).and_then(|page| page.char_at(current.point))
    {
        selection.focus = index;
    }

    if let Some(click) = response.click {
        if let Some(link) = link_at(tab, click.page, click.point) {
            return match link.target {
                LinkTarget::Page(index) if index < tab.session.editor.page_count() => {
                    tab.navigate_to(index);
                    InteractionAction::None
                }
                LinkTarget::Page(_) => InteractionAction::None,
                LinkTarget::Uri(uri) => {
                    let scheme = uri.split(':').next().unwrap_or_default().to_ascii_lowercase();
                    if matches!(scheme.as_str(), "http" | "https" | "mailto") {
                        InteractionAction::ConfirmExternalLink(uri)
                    } else {
                        InteractionAction::RejectedLink
                    }
                }
            };
        }
        tab.selection = None;
    }
    if let Some(double) = response.double_click
        && let Some(text) = tab.text_index(ctx)
        && let Some(page) = text.get(double.page)
        && let Some(index) = page.char_at(double.point)
    {
        let is_word = |c: char| c.is_alphanumeric() || c == '_' || c == '\'';
        let mut start = index;
        while start > 0 && is_word(page.chars[start - 1]) {
            start -= 1;
        }
        let mut end = index;
        while end + 1 < page.chars.len() && is_word(page.chars[end + 1]) {
            end += 1;
        }
        tab.selection = Some(TextSelection {
            page: double.page,
            anchor: start,
            focus: end,
        });
    }
    InteractionAction::None
}

/// Search hits and the text selection.
pub fn paint_text_overlays(painter: &Painter, ctx: &egui::Context, tab: &mut DocumentTab, response: &ReaderResponse) {
    let active = tab.search.active;
    for (index, found) in tab.search.matches().iter().enumerate() {
        let Some(view) = response.page(found.page) else { continue };
        let fill = if Some(index) == active { SEARCH_ACTIVE } else { SEARCH_HIGHLIGHT };
        for rect in &found.boxes {
            let screen = view.box_to_screen(rect).expand(1.0);
            painter.rect_filled(screen, CornerRadius::same(2), fill);
            if tab.search.marked.contains(&index) {
                painter.rect_stroke(screen, CornerRadius::same(2), Stroke::new(1.5, mocha::RED), StrokeKind::Outside);
            }
        }
    }
    if let Some(selection) = tab.selection.clone()
        && let Some(view) = response.page(selection.page)
        && let Some(text) = tab.text_index(ctx)
        && let Some(page) = text.get(selection.page)
    {
        let (start, end) = selection.range();
        for rect in page.line_boxes(start, end) {
            painter.rect_filled(view.box_to_screen(&rect), CornerRadius::ZERO, TEXT_SELECTION);
        }
    }
}
