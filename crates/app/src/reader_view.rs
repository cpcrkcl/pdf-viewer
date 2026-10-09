//! The central page canvas.

use egui::{Align2, Color32, CornerRadius, FontId, Pos2, Rect, Sense, Shadow, Stroke, StrokeKind, Ui, Vec2, pos2, vec2};

use crate::document_tab::DocumentTab;
use crate::reader_state::{DisplayMode, MAX_ZOOM, MIN_ZOOM, Zoom};
use crate::render::{RenderService, TextureKey, bucketed_width};
use crate::theme;

const PAGE_GAP: f32 = 16.0;
const MARGIN: f32 = 24.0;

/// Where each page sits in content coordinates for the current layout.
pub struct PageLayout {
    pub rects: Vec<Option<Rect>>,
    pub content_size: Vec2,
}

pub fn effective_scale(tab: &DocumentTab, viewport_width: f32) -> f32 {
    match tab.reader.zoom {
        Zoom::Scale(scale) => scale,
        Zoom::FitWidth => {
            let widest = match tab.reader.display_mode {
                DisplayMode::TwoPage => tab
                    .metrics
                    .chunks(2)
                    .map(|pair| pair.iter().map(|m| m.size.x).sum::<f32>() + PAGE_GAP * (pair.len() as f32 - 1.0))
                    .fold(1.0, f32::max),
                _ => tab.metrics.iter().map(|m| m.size.x).fold(1.0, f32::max),
            };
            ((viewport_width - 2.0 * MARGIN) / widest).clamp(MIN_ZOOM, MAX_ZOOM)
        }
    }
}

pub fn layout(tab: &DocumentTab, scale: f32, viewport_width: f32) -> PageLayout {
    let sizes: Vec<Vec2> = tab.metrics.iter().map(|m| m.size * scale).collect();
    let mut rects = vec![None; sizes.len()];
    let mut y = MARGIN;
    let mut max_width: f32 = 0.0;
    match tab.reader.display_mode {
        DisplayMode::Continuous => {
            for (index, size) in sizes.iter().enumerate() {
                rects[index] = Some(Rect::from_min_size(pos2(0.0, y), *size));
                y += size.y + PAGE_GAP;
                max_width = max_width.max(size.x);
            }
        }
        DisplayMode::TwoPage => {
            for (row, pair) in sizes.chunks(2).enumerate() {
                let row_height = pair.iter().map(|size| size.y).fold(0.0, f32::max);
                let mut x = 0.0;
                for (offset, size) in pair.iter().enumerate() {
                    let top = y + (row_height - size.y) / 2.0;
                    rects[row * 2 + offset] = Some(Rect::from_min_size(pos2(x, top), *size));
                    x += size.x + PAGE_GAP;
                }
                max_width = max_width.max(x - PAGE_GAP);
                y += row_height + PAGE_GAP;
            }
        }
        DisplayMode::SinglePage => {
            let index = tab.reader.selected_page_index();
            if let Some(size) = sizes.get(index) {
                rects[index] = Some(Rect::from_min_size(pos2(0.0, y), *size));
                y += size.y + PAGE_GAP;
                max_width = size.x;
            }
        }
    }
    let content_width = (max_width + 2.0 * MARGIN).max(viewport_width);
    // Center rows horizontally.
    if tab.reader.display_mode == DisplayMode::TwoPage {
        let mut index = 0;
        while index < rects.len() {
            let row: Vec<usize> = (index..(index + 2).min(rects.len())).collect();
            let row_width = row
                .iter()
                .filter_map(|i| rects[*i])
                .map(|r| r.max.x)
                .fold(0.0, f32::max);
            let shift = (content_width - row_width) / 2.0;
            for i in row {
                if let Some(rect) = rects[i].as_mut() {
                    *rect = rect.translate(vec2(shift, 0.0));
                }
            }
            index += 2;
        }
    } else {
        for rect in rects.iter_mut().flatten() {
            *rect = rect.translate(vec2((content_width - rect.width()) / 2.0, 0.0));
        }
    }
    PageLayout {
        rects,
        content_size: vec2(content_width, y - PAGE_GAP + MARGIN),
    }
}

pub struct ReaderResponse {
    /// Screen rect of each visible page, for overlays (annotations, search hits).
    pub visible_pages: Vec<(usize, Rect)>,
    pub scale: f32,
    pub canvas: Rect,
}

pub fn show(ui: &mut Ui, tab: &mut DocumentTab, renderer: &mut RenderService) -> ReaderResponse {
    tab.refresh_metrics();
    let available = ui.available_size();
    let canvas = ui.available_rect_before_wrap();
    ui.painter().rect_filled(canvas, CornerRadius::ZERO, theme::workspace_color(tab.reader.theme));

    // Pinch or Cmd+scroll zoom, anchored at the current scale.
    let pointer_over = ui.rect_contains_pointer(canvas);
    let zoom_delta = if pointer_over { ui.ctx().input(|input| input.zoom_delta()) } else { 1.0 };
    let mut scale = effective_scale(tab, available.x);
    if (zoom_delta - 1.0).abs() > f32::EPSILON {
        scale = (scale * zoom_delta).clamp(MIN_ZOOM, MAX_ZOOM);
        tab.reader.zoom = Zoom::Scale(scale);
    }
    tab.reader.effective_scale = scale;

    let page_layout = layout(tab, scale, available.x);
    let mut scroll_area = egui::ScrollArea::both()
        .id_salt(("reader", tab.id))
        .auto_shrink([false, false]);
    if let Some(target) = tab.scroll_to_page.take()
        && let Some(Some(rect)) = page_layout.rects.get(target)
    {
        scroll_area = scroll_area.vertical_scroll_offset((rect.min.y - MARGIN / 2.0).max(0.0));
    }

    let pixels_per_point = ui.ctx().pixels_per_point();
    let document_key = tab.document_key();
    let bytes = tab.pdf_data();
    let mut visible_pages = Vec::new();
    let mut center_page = None;

    scroll_area.show_viewport(ui, |ui, viewport| {
        let (content_rect, _) = ui.allocate_exact_size(page_layout.content_size, Sense::hover());
        let origin = content_rect.min.to_vec2();
        let probe_y = viewport.min.y + viewport.height() * 0.35;
        let mut best_distance = f32::MAX;
        for (index, rect) in page_layout.rects.iter().enumerate() {
            let Some(rect) = rect else { continue };
            let distance = if rect.y_range().contains(probe_y) { 0.0 } else { (rect.center().y - probe_y).abs() };
            if distance < best_distance {
                best_distance = distance;
                center_page = Some(index);
            }
            // Render a little beyond the viewport so scrolling reveals finished pages.
            if !rect.intersects(viewport.expand2(vec2(0.0, viewport.height() * 0.5))) {
                continue;
            }
            let screen_rect = rect.translate(origin);
            draw_page(ui, renderer, screen_rect, index, document_key, &bytes, pixels_per_point);
            if rect.intersects(viewport) {
                visible_pages.push((index, screen_rect));
            }
        }
    });

    if tab.reader.display_mode != DisplayMode::SinglePage
        && let Some(page) = center_page
        && page != tab.reader.selected_page_index()
    {
        tab.reader.set_current_page(page);
        tab.go_to_page_text = (page + 1).to_string();
    }

    ReaderResponse {
        visible_pages,
        scale,
        canvas,
    }
}

fn draw_page(
    ui: &Ui,
    renderer: &mut RenderService,
    rect: Rect,
    index: usize,
    document: crate::render::DocumentKey,
    bytes: &std::sync::Arc<Vec<u8>>,
    pixels_per_point: f32,
) {
    let painter = ui.painter();
    painter.add(Shadow {
        offset: [0, 3],
        blur: 12,
        spread: 0,
        color: theme::PAGE_SHADOW,
    }.as_shape(rect, CornerRadius::ZERO));
    painter.rect_filled(rect, CornerRadius::ZERO, Color32::WHITE);
    let key = TextureKey {
        document,
        page: index,
        width_px: bucketed_width(rect.width() * pixels_per_point),
    };
    match renderer.texture(key, bytes) {
        Some(texture) => {
            painter.image(texture.id(), rect, Rect::from_min_max(Pos2::ZERO, pos2(1.0, 1.0)), Color32::WHITE);
        }
        None => {
            painter.text(
                rect.center(),
                Align2::CENTER_CENTER,
                format!("Page {}", index + 1),
                FontId::proportional(14.0),
                Color32::from_gray(150),
            );
        }
    }
    painter.rect_stroke(rect, CornerRadius::ZERO, Stroke::new(0.5, Color32::from_black_alpha(60)), StrokeKind::Outside);
}
