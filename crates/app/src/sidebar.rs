//! Thumbnails, outline and bookmarks.

use std::collections::BTreeSet;

use egui::{Align2, Color32, CornerRadius, FontId, Rect, Sense, Stroke, StrokeKind, Ui, pos2, vec2};
use pdf_core::navigation::PageBookmarkStore;
use pdf_core::outline::OutlineNode;

use crate::document_tab::DocumentTab;
use crate::reader_state::SidebarTab;
use crate::render::{RenderService, TextureKey, bucketed_width};
use crate::theme::{self, mocha};

pub enum SidebarAction {
    None,
    RenameBookmark(uuid::Uuid),
}

pub fn show(
    ui: &mut Ui,
    tab: &mut DocumentTab,
    renderer: &mut RenderService,
    bookmarks: &mut PageBookmarkStore,
) -> SidebarAction {
    ui.horizontal_wrapped(|ui| {
        for candidate in SidebarTab::ALL {
            ui.selectable_value(&mut tab.reader.sidebar_tab, candidate, candidate.title());
        }
    });
    ui.separator();
    match tab.reader.sidebar_tab {
        SidebarTab::Thumbnails => {
            thumbnails(ui, tab, renderer);
            SidebarAction::None
        }
        SidebarTab::Contents => {
            contents(ui, tab);
            SidebarAction::None
        }
        SidebarTab::Bookmarks => bookmark_list(ui, tab, bookmarks),
        SidebarTab::Annotations => {
            crate::annotation_ui::annotation_list(ui, tab);
            SidebarAction::None
        }
    }
}

fn thumbnails(ui: &mut Ui, tab: &mut DocumentTab, renderer: &mut RenderService) {
    let width = (ui.available_width() - 24.0).max(60.0);
    let pixels_per_point = ui.ctx().pixels_per_point();
    let key = tab.document_key();
    let bytes = tab.pdf_data();
    let heights: Vec<f32> = tab
        .metrics
        .iter()
        .map(|metrics| width * metrics.size.y / metrics.size.x.max(1.0) + 26.0)
        .collect();
    let row_height = heights.iter().copied().fold(0.0, f32::max).max(40.0);
    let selected = tab.reader.selected_page_indexes().clone();
    let current = tab.reader.selected_page_index();
    let mut clicked: Option<(usize, egui::Modifiers)> = None;

    egui::ScrollArea::vertical()
        .id_salt(("thumbs", tab.id))
        .auto_shrink([false, false])
        .show_rows(ui, row_height, tab.metrics.len(), |ui, range| {
            for index in range {
                let (rect, response) = ui.allocate_exact_size(vec2(ui.available_width(), row_height), Sense::click());
                let metrics = &tab.metrics[index];
                let image_height = width * metrics.size.y / metrics.size.x.max(1.0);
                let image_rect = Rect::from_min_size(
                    pos2(rect.center().x - width / 2.0, rect.min.y + 4.0),
                    vec2(width, image_height.min(row_height - 26.0)),
                );
                let painter = ui.painter();
                if selected.contains(&index) {
                    painter.rect_filled(rect.shrink(1.0), CornerRadius::same(6), theme::SELECTION.linear_multiply(0.18));
                }
                painter.rect_filled(image_rect, CornerRadius::ZERO, Color32::WHITE);
                let texture_key = TextureKey {
                    document: key,
                    page: index,
                    width_px: bucketed_width(width * pixels_per_point),
                };
                if let Some(texture) = renderer.texture(texture_key, &bytes) {
                    painter.image(texture.id(), image_rect, Rect::from_min_max(pos2(0.0, 0.0), pos2(1.0, 1.0)), Color32::WHITE);
                }
                let stroke = if index == current {
                    Stroke::new(2.0, theme::SELECTION)
                } else {
                    Stroke::new(0.5, mocha::SURFACE2)
                };
                painter.rect_stroke(image_rect, CornerRadius::ZERO, stroke, StrokeKind::Outside);
                painter.text(
                    pos2(rect.center().x, image_rect.max.y + 11.0),
                    Align2::CENTER_CENTER,
                    tab.page_label(index),
                    FontId::proportional(11.0),
                    mocha::SUBTEXT0,
                );
                if response.clicked() {
                    clicked = Some((index, ui.input(|input| input.modifiers)));
                }
            }
        });

    if let Some((index, modifiers)) = clicked {
        if modifiers.command {
            let mut indexes = selected;
            if !indexes.remove(&index) {
                indexes.insert(index);
            }
            if indexes.is_empty() {
                indexes.insert(index);
            }
            tab.reader.select_pages(indexes, Some(index));
        } else if modifiers.shift {
            let anchor = current;
            let range: BTreeSet<usize> = (anchor.min(index)..=anchor.max(index)).collect();
            tab.reader.select_pages(range, Some(index));
            tab.scroll_to_page = Some(index);
        } else {
            tab.show_page(index);
        }
    }
}

fn contents(ui: &mut Ui, tab: &mut DocumentTab) {
    if tab.session.outline.is_empty() {
        ui.weak("This PDF has no table of contents.");
        return;
    }
    let mut target = None;
    egui::ScrollArea::vertical()
        .id_salt(("outline", tab.id))
        .auto_shrink([false, false])
        .show(ui, |ui| {
            for node in &tab.session.outline {
                outline_node(ui, node, &mut target);
            }
        });
    if let Some(page_id) = target {
        tab.navigate_to_page_id(&page_id);
    }
}

fn outline_node(ui: &mut Ui, node: &OutlineNode, target: &mut Option<pdf_core::WorkingPageId>) {
    let mut label = |ui: &mut Ui| {
        let response = ui.add_enabled(node.is_navigable(), egui::Button::new(&node.title).frame(false));
        if response.clicked() {
            *target = node.page_id.clone();
        }
    };
    if node.children.is_empty() {
        ui.horizontal(|ui| {
            ui.add_space(18.0);
            label(ui);
        });
    } else {
        egui::collapsing_header::CollapsingState::load_with_default_open(ui.ctx(), ui.make_persistent_id(&node.id), false)
            .show_header(ui, label)
            .body(|ui| {
                for child in &node.children {
                    outline_node(ui, child, target);
                }
            });
    }
}

fn bookmark_list(ui: &mut Ui, tab: &mut DocumentTab, bookmarks: &mut PageBookmarkStore) -> SidebarAction {
    let mut action = SidebarAction::None;
    if ui.button("Add Bookmark for Current Page").clicked() {
        let index = tab.reader.selected_page_index();
        if let Some(page_id) = tab.session.editor.page_id(index).cloned() {
            bookmarks.add(&tab.session.fingerprint, page_id, &format!("Page {}", tab.page_label(index)));
        }
    }
    ui.separator();
    let list = bookmarks.bookmarks_for(&tab.session.fingerprint);
    if list.is_empty() {
        ui.weak("No bookmarks yet.");
    }
    let mut navigate = None;
    let mut remove = None;
    egui::ScrollArea::vertical()
        .id_salt(("bookmarks", tab.id))
        .auto_shrink([false, false])
        .show(ui, |ui| {
            for bookmark in list {
                let index = tab.session.editor.index_of(&bookmark.page_id);
                ui.horizontal(|ui| {
                    let text = match index {
                        Some(index) => format!("{}  ·  p. {}", bookmark.label, tab.page_label(index)),
                        None => format!("{}  ·  page removed", bookmark.label),
                    };
                    if ui.add_enabled(index.is_some(), egui::Button::new(text).frame(false)).clicked() {
                        navigate = Some(bookmark.page_id.clone());
                    }
                    ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                        if ui.small_button("✕").on_hover_text("Delete bookmark").clicked() {
                            remove = Some(bookmark.id);
                        }
                        if ui.small_button("✎").on_hover_text("Rename bookmark").clicked() {
                            action = SidebarAction::RenameBookmark(bookmark.id);
                        }
                    });
                });
            }
        });
    if let Some(page_id) = navigate {
        tab.navigate_to_page_id(&page_id);
    }
    if let Some(id) = remove {
        bookmarks.remove(id);
    }
    action
}
