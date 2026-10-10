//! Thumbnails, outline and bookmarks.

use std::collections::BTreeSet;

use egui::{
    Align2, Color32, CornerRadius, FontId, Rect, Sense, Stroke, StrokeKind, Ui, pos2, vec2,
};
use pdf_core::navigation::PageBookmarkStore;
use pdf_core::outline::OutlineNode;

use crate::document_tab::DocumentTab;
use crate::icons::{self, Icon};
use crate::reader_state::SidebarTab;
use crate::render::{RenderService, TextureKey, bucketed_width};
use crate::theme;

pub enum SidebarAction {
    None,
    RenameBookmark(uuid::Uuid),
    Command(crate::commands::Command),
    MovePages {
        pages: Vec<usize>,
        destination: usize,
        generation: u64,
    },
}

pub fn show(
    ui: &mut Ui,
    tab: &mut DocumentTab,
    renderer: &mut RenderService,
    bookmarks: &mut PageBookmarkStore,
) -> SidebarAction {
    section_picker(ui, &mut tab.reader.sidebar_tab);
    match tab.reader.sidebar_tab {
        SidebarTab::Thumbnails => thumbnails(ui, tab, renderer),
        SidebarTab::Contents => {
            contents(ui, tab);
            SidebarAction::None
        }
        SidebarTab::Bookmarks => bookmark_list(ui, tab, bookmarks),
        SidebarTab::Annotations => {
            crate::annotation_ui::annotation_list(ui, tab);
            SidebarAction::None
        }
        SidebarTab::Search => {
            search_results(ui, tab);
            SidebarAction::None
        }
    }
}

/// One icon per section, spread across the sidebar like a segmented control.
fn section_picker(ui: &mut Ui, current: &mut SidebarTab) {
    let colors = theme::colors();
    ui.add_space(2.0);
    let (rect, _) = ui.allocate_exact_size(vec2(ui.available_width(), 30.0), Sense::hover());
    ui.painter().rect_filled(
        rect,
        CornerRadius::same(8),
        colors
            .well
            .gamma_multiply(if colors.dark { 0.7 } else { 0.6 }),
    );
    let count = SidebarTab::ALL.len() as f32;
    let slot = (rect.width() - 4.0) / count;
    for (index, candidate) in SidebarTab::ALL.into_iter().enumerate() {
        let cell = Rect::from_min_size(
            pos2(rect.min.x + 2.0 + slot * index as f32, rect.min.y + 2.0),
            vec2(slot, rect.height() - 4.0),
        );
        let response = ui.interact(
            cell,
            ui.id().with(("sidebar-section", index)),
            Sense::click(),
        );
        let selected = *current == candidate;
        let painter = ui.painter();
        if selected {
            painter.rect_filled(cell, CornerRadius::same(6), colors.raised);
            painter.rect_stroke(
                cell,
                CornerRadius::same(6),
                Stroke::new(1.0, colors.hairline),
                StrokeKind::Inside,
            );
        } else if response.hovered() {
            painter.rect_filled(cell, CornerRadius::same(6), colors.hover);
        }
        let icon = match candidate {
            SidebarTab::Thumbnails => Icon::Thumbnails,
            SidebarTab::Contents => Icon::Contents,
            SidebarTab::Bookmarks => Icon::Bookmark,
            SidebarTab::Annotations => Icon::Annotations,
            SidebarTab::Search => Icon::Search,
        };
        let color = if selected {
            colors.accent
        } else {
            colors.muted
        };
        icons::paint(
            painter,
            Rect::from_center_size(cell.center(), vec2(15.0, 15.0)),
            icon,
            color,
        );
        if response.on_hover_text(candidate.title()).clicked() {
            *current = candidate;
        }
    }
    ui.add_space(6.0);
}

/// A muted one-line hint for empty sections.
fn hint(ui: &mut Ui, text: &str) {
    ui.add_space(8.0);
    ui.label(
        egui::RichText::new(text)
            .color(theme::colors().muted)
            .size(12.0),
    );
}

struct DraggedPages {
    tab: u64,
    pages: Vec<usize>,
    generation: u64,
}

fn thumbnails(ui: &mut Ui, tab: &mut DocumentTab, renderer: &mut RenderService) -> SidebarAction {
    let mut action = SidebarAction::None;
    let can_edit = tab.session.security.allows_document_assembly();
    ui.horizontal(|ui| {
        ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
            ui.add_enabled_ui(can_edit, |ui| {
                if ui
                    .small_button("Rotate")
                    .on_hover_text("Rotate selected pages")
                    .clicked()
                {
                    action = SidebarAction::Command(crate::commands::Command::RotateRight);
                }
                if ui.small_button("Extract").clicked() {
                    action = SidebarAction::Command(crate::commands::Command::ExtractPages);
                }
                if ui
                    .add_enabled(
                        tab.reader.selected_page_indexes().len() < tab.pages.len(),
                        egui::Button::new("Delete").small(),
                    )
                    .clicked()
                {
                    action = SidebarAction::Command(crate::commands::Command::DeletePages);
                }
            });
        });
    });
    ui.weak(format!(
        "{} selected · drag to reorder",
        tab.reader.selected_page_indexes().len()
    ));
    let width = (ui.available_width() - 44.0).max(60.0);
    let pixels_per_point = ui.ctx().pixels_per_point();
    let key = tab.document_key();
    let bytes = tab.pdf_data();
    let row_height = crate::reader_view::thumbnail_row_height(tab, width);
    let selected = tab.reader.selected_page_indexes().clone();
    let current = tab.reader.selected_page_index();
    let mut clicked: Option<(usize, egui::Modifiers)> = None;

    egui::ScrollArea::vertical()
        .id_salt(("thumbs", tab.id))
        .auto_shrink([false, false])
        .show_rows(ui, row_height, tab.pages.len(), |ui, range| {
            for index in range {
                let (rect, response) = ui.allocate_exact_size(
                    vec2(ui.available_width(), row_height),
                    Sense::click_and_drag(),
                );
                let size = tab.page_size(index);
                let image_height = width * size.y / size.x.max(1.0);
                let image_rect = Rect::from_min_size(
                    pos2(rect.center().x - width / 2.0, rect.min.y + 6.0),
                    vec2(width, image_height.min(row_height - 34.0)),
                );
                let colors = theme::colors();
                let painter = ui.painter();
                let is_current = index == current;
                let ring = image_rect.expand(4.0);
                if is_current {
                    painter.rect_stroke(
                        ring,
                        CornerRadius::same(5),
                        Stroke::new(2.0, colors.accent),
                        StrokeKind::Middle,
                    );
                } else if selected.contains(&index) {
                    painter.rect_stroke(
                        ring,
                        CornerRadius::same(5),
                        Stroke::new(2.0, colors.accent.gamma_multiply(0.5)),
                        StrokeKind::Middle,
                    );
                } else if response.hovered() {
                    painter.rect_stroke(
                        ring,
                        CornerRadius::same(5),
                        Stroke::new(2.0, colors.hover),
                        StrokeKind::Middle,
                    );
                }
                painter.add(
                    egui::Shadow {
                        offset: [0, 1],
                        blur: 4,
                        spread: 0,
                        color: theme::page_shadow().gamma_multiply(0.6),
                    }
                    .as_shape(image_rect, 0),
                );
                painter.rect_filled(image_rect, CornerRadius::ZERO, Color32::WHITE);
                let texture_key = TextureKey {
                    document: key,
                    page: index,
                    width_px: bucketed_width(width * pixels_per_point),
                };
                if let Some(texture) = renderer.texture(texture_key, &bytes) {
                    painter.image(
                        texture.id(),
                        image_rect,
                        Rect::from_min_max(pos2(0.0, 0.0), pos2(1.0, 1.0)),
                        Color32::WHITE,
                    );
                }
                let label_pos = pos2(rect.center().x, image_rect.max.y + 14.0);
                let font = FontId::proportional(11.0);
                if is_current {
                    let galley =
                        painter.layout_no_wrap(tab.page_label(index), font, colors.on_accent);
                    let pill = Rect::from_center_size(label_pos, galley.size() + vec2(12.0, 3.0));
                    painter.rect_filled(pill, CornerRadius::same(8), colors.accent);
                    painter.galley(
                        pill.center() - galley.size() / 2.0,
                        galley,
                        colors.on_accent,
                    );
                } else {
                    painter.text(
                        label_pos,
                        Align2::CENTER_CENTER,
                        tab.page_label(index),
                        font,
                        colors.muted,
                    );
                }
                if can_edit && response.drag_started() {
                    let pages = if selected.contains(&index) {
                        selected.iter().copied().collect()
                    } else {
                        vec![index]
                    };
                    response.dnd_set_drag_payload(DraggedPages {
                        tab: tab.id,
                        pages,
                        generation: tab.generation(),
                    });
                    if !selected.contains(&index) {
                        clicked = Some((index, egui::Modifiers::NONE));
                    }
                }
                if let Some(payload) = response.dnd_hover_payload::<DraggedPages>()
                    && payload.tab == tab.id
                    && payload.generation == tab.generation()
                {
                    let before = ui
                        .input(|input| input.pointer.interact_pos())
                        .is_none_or(|p| p.y < rect.center().y);
                    let y = if before { rect.min.y } else { rect.max.y };
                    painter.line_segment(
                        [pos2(rect.min.x, y), pos2(rect.max.x, y)],
                        Stroke::new(2.0, theme::colors().accent),
                    );
                }
                if let Some(payload) = response.dnd_release_payload::<DraggedPages>()
                    && can_edit
                    && payload.tab == tab.id
                {
                    let before = ui
                        .input(|input| input.pointer.interact_pos())
                        .is_none_or(|p| p.y < rect.center().y);
                    action = SidebarAction::MovePages {
                        pages: payload.pages.clone(),
                        destination: index + usize::from(!before),
                        generation: payload.generation,
                    };
                }
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
    action
}

fn contents(ui: &mut Ui, tab: &mut DocumentTab) {
    if tab.session.outline.is_empty() {
        hint(ui, "This PDF has no table of contents.");
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
        let response = ui.add_enabled(
            node.is_navigable(),
            egui::Button::new(&node.title).frame(false),
        );
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
        egui::collapsing_header::CollapsingState::load_with_default_open(
            ui.ctx(),
            ui.make_persistent_id(&node.id),
            false,
        )
        .show_header(ui, label)
        .body(|ui| {
            for child in &node.children {
                outline_node(ui, child, target);
            }
        });
    }
}

fn bookmark_list(
    ui: &mut Ui,
    tab: &mut DocumentTab,
    bookmarks: &mut PageBookmarkStore,
) -> SidebarAction {
    let mut action = SidebarAction::None;
    let add = egui::Button::new("Bookmark This Page").min_size(vec2(ui.available_width(), 26.0));
    if ui.add(add).on_hover_text("⌘D").clicked() {
        let index = tab.reader.selected_page_index();
        if let Some(page_id) = tab.session.editor.page_id(index).cloned() {
            bookmarks.add(
                &tab.session.fingerprint,
                page_id,
                &format!("Page {}", tab.page_label(index)),
            );
        }
    }
    ui.add_space(4.0);
    let list = bookmarks.bookmarks_for(&tab.session.fingerprint);
    if list.is_empty() {
        hint(ui, "No bookmarks yet. Bookmark a page with ⌘D.");
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
                        Some(index) => {
                            format!("{}  ·  p. {}", bookmark.label, tab.page_label(index))
                        }
                        None => format!("{}  ·  page removed", bookmark.label),
                    };
                    if ui
                        .add_enabled(index.is_some(), egui::Button::new(text).frame(false))
                        .clicked()
                    {
                        navigate = Some(bookmark.page_id.clone());
                    }
                    ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                        if ui
                            .small_button("✕")
                            .on_hover_text("Delete bookmark")
                            .clicked()
                        {
                            remove = Some(bookmark.id);
                        }
                        if ui
                            .small_button("✎")
                            .on_hover_text("Rename bookmark")
                            .clicked()
                        {
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

fn search_results(ui: &mut Ui, tab: &mut DocumentTab) {
    use pdf_core::text::SearchOutcome;
    match &tab.search.outcome {
        None if tab.search.is_running() => {
            ui.horizontal(|ui| {
                ui.spinner();
                ui.label("Searching…");
            });
            return;
        }
        None => {
            hint(ui, "Type in the search field and press Return.");
            return;
        }
        Some(SearchOutcome::TextUnavailable) => {
            hint(
                ui,
                "This PDF has no searchable text. Run OCR to make scanned pages searchable.",
            );
            return;
        }
        Some(SearchOutcome::NoMatches) => {
            hint(ui, "No matches.");
            return;
        }
        Some(SearchOutcome::Matches(_)) => {}
    }
    let count = tab.search.matches().len();
    ui.label(format!(
        "{count} match{}",
        if count == 1 { "" } else { "es" }
    ));
    ui.horizontal(|ui| {
        if ui.small_button("Mark All").clicked() {
            tab.search.marked = (0..count).collect();
        }
        if ui.small_button("Clear Marks").clicked() {
            tab.search.marked.clear();
        }
    });
    ui.separator();
    let mut select = None;
    let active = tab.search.active;
    let labels: Vec<String> = tab
        .search
        .matches()
        .iter()
        .map(|found| tab.page_label(found.page))
        .collect();
    egui::ScrollArea::vertical()
        .id_salt(("search-results", tab.id))
        .auto_shrink([false, false])
        .show_rows(ui, 22.0, count, |ui, range| {
            for index in range {
                let found = &tab.search.matches()[index];
                let colors = theme::colors();
                let mut text = egui::text::LayoutJob::default();
                let page = egui::TextFormat {
                    font_id: FontId::proportional(11.0),
                    color: colors.muted,
                    valign: egui::Align::Center,
                    ..Default::default()
                };
                let body = egui::TextFormat {
                    font_id: FontId::proportional(13.0),
                    color: colors.text,
                    valign: egui::Align::Center,
                    ..Default::default()
                };
                text.append(&format!("p. {}", labels[index]), 0.0, page);
                text.append(&found.text.replace('\n', " "), 8.0, body);
                ui.horizontal(|ui| {
                    let mut marked = tab.search.marked.contains(&index);
                    if ui
                        .checkbox(&mut marked, "")
                        .on_hover_text("Mark for redaction")
                        .changed()
                    {
                        if marked {
                            tab.search.marked.insert(index);
                        } else {
                            tab.search.marked.remove(&index);
                        }
                    }
                    if ui.selectable_label(active == Some(index), text).clicked() {
                        select = Some(index);
                    }
                });
            }
        });
    if let Some(index) = select {
        tab.select_search_match(Some(index));
    }
}
