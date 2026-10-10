//! The central page canvas.

use egui::{
    Align2, Color32, CornerRadius, FontId, Pos2, Rect, Sense, Shadow, Stroke, StrokeKind, Ui, Vec2,
    pos2, vec2,
};
use pdf_core::geometry::{PageGeometry, PdfBox};

use crate::document_tab::DocumentTab;
use crate::reader_state::{DisplayMode, MAX_ZOOM, MIN_ZOOM, Zoom};
use crate::render::{RenderPriority, RenderService, TextureKey, bucketed_width};
use crate::theme;
use std::sync::Arc;

const PAGE_GAP: f32 = 16.0;
const MARGIN: f32 = 24.0;

/// A page as drawn this frame: maps between PDF user space and the screen.
#[derive(Debug, Clone, Copy)]
pub struct PageView {
    pub index: usize,
    pub rect: Rect,
    pub scale: f32,
    pub geometry: PageGeometry,
}

impl PageView {
    pub fn to_screen(&self, point: (f32, f32)) -> Pos2 {
        let (x, y) = self.geometry.to_display(point);
        self.rect.min + vec2(x, y) * self.scale
    }

    pub fn from_screen(&self, position: Pos2) -> (f32, f32) {
        let local = (position - self.rect.min) / self.scale;
        self.geometry.from_display((local.x, local.y))
    }

    pub fn box_to_screen(&self, rect: &PdfBox) -> Rect {
        let (min, max) = self.geometry.box_to_display(rect);
        Rect::from_min_max(
            self.rect.min + vec2(min.0, min.1) * self.scale,
            self.rect.min + vec2(max.0, max.1) * self.scale,
        )
    }

    pub fn screen_to_box(&self, rect: Rect) -> PdfBox {
        PdfBox::from_points(self.from_screen(rect.min), self.from_screen(rect.max))
    }
}

/// Where each page sits in content coordinates for the current layout.
#[derive(Default)]
pub struct LayoutCache {
    layouts: Vec<(LayoutKey, Arc<PageLayout>)>,
    widths: Option<(u64, [f32; 2])>,
    aspect: Option<f32>,
}

#[derive(Clone, Copy, PartialEq)]
struct LayoutKey {
    generation: u64,
    scale: f32,
    width: f32,
    mode: DisplayMode,
    page: usize,
}

impl LayoutCache {
    pub fn clear(&mut self) {
        *self = Self::default();
    }
    pub fn preserve_generation(&mut self, generation: u64) {
        for (key, _) in &mut self.layouts {
            key.generation = generation;
        }
        if let Some((stored, _)) = &mut self.widths {
            *stored = generation;
        }
    }
}

struct LayoutRow {
    top: f32,
    bottom: f32,
    pages: std::ops::Range<usize>,
}

pub struct PageLayout {
    rows: Vec<LayoutRow>,
    pub rects: Vec<Option<Rect>>,
    pub content_size: Vec2,
}

impl PageLayout {
    /// Rows have monotonic bounds even when the pages of a spread have different sizes.
    pub fn visible_range(&self, viewport: Rect) -> std::ops::Range<usize> {
        let first = self.rows.partition_point(|row| row.bottom < viewport.min.y);
        let end = self.rows.partition_point(|row| row.top <= viewport.max.y);
        if first >= end {
            return 0..0;
        }
        self.rows[first].pages.start..self.rows[end - 1].pages.end
    }
}

pub fn thumbnail_row_height(tab: &mut DocumentTab, width: f32) -> f32 {
    let aspect = match tab.layout_cache.aspect {
        Some(aspect) => aspect,
        None => {
            let aspect = (0..tab.pages.len())
                .map(|index| {
                    let size = tab.page_size(index);
                    size.y / size.x.max(1.0)
                })
                .fold(0.0, f32::max);
            tab.layout_cache.aspect = Some(aspect);
            aspect
        }
    };
    (width * aspect + 34.0).max(40.0)
}

pub fn effective_scale(tab: &mut DocumentTab, viewport_width: f32) -> f32 {
    match tab.reader.zoom {
        Zoom::Scale(scale) => scale,
        Zoom::FitWidth => {
            if tab
                .layout_cache
                .widths
                .as_ref()
                .is_none_or(|(generation, _)| *generation != tab.generation())
            {
                let mut single: f32 = 1.0;
                let mut spread: f32 = 1.0;
                for first in (0..tab.pages.len()).step_by(2) {
                    let a = tab.page_size(first).x;
                    let b = (first + 1 < tab.pages.len()).then(|| tab.page_size(first + 1).x);
                    single = single.max(a).max(b.unwrap_or(0.0));
                    spread = spread.max(a + b.map_or(0.0, |width| width + PAGE_GAP));
                }
                tab.layout_cache.widths = Some((tab.generation(), [single, spread]));
            }
            let widths = tab.layout_cache.widths.as_ref().unwrap().1;
            let widest = widths[usize::from(tab.reader.display_mode == DisplayMode::TwoPage)];
            ((viewport_width - 2.0 * MARGIN - 12.0) / widest).clamp(MIN_ZOOM, MAX_ZOOM)
        }
    }
}

pub fn cached_layout(tab: &mut DocumentTab, scale: f32, width: f32) -> Arc<PageLayout> {
    let key = LayoutKey {
        generation: tab.generation(),
        scale,
        width,
        mode: tab.reader.display_mode,
        page: if tab.reader.display_mode == DisplayMode::SinglePage {
            tab.reader.selected_page_index()
        } else {
            0
        },
    };
    if let Some((_, layout)) = tab
        .layout_cache
        .layouts
        .iter()
        .find(|(candidate, _)| *candidate == key)
    {
        return Arc::clone(layout);
    }
    let layout = Arc::new(layout(tab, scale, width));
    if tab.layout_cache.layouts.len() >= 2 {
        tab.layout_cache.layouts.remove(0);
    }
    tab.layout_cache.layouts.push((key, Arc::clone(&layout)));
    layout
}

pub fn layout(tab: &DocumentTab, scale: f32, viewport_width: f32) -> PageLayout {
    let sizes: Vec<Vec2> = (0..tab.pages.len())
        .map(|i| tab.page_size(i) * scale)
        .collect();
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
    if tab.reader.display_mode == DisplayMode::TwoPage {
        for first in (0..rects.len()).step_by(2) {
            let row: Vec<usize> = (first..(first + 2).min(rects.len())).collect();
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
        }
    } else {
        for rect in rects.iter_mut().flatten() {
            *rect = rect.translate(vec2((content_width - rect.width()) / 2.0, 0.0));
        }
    }
    let mut rows = Vec::new();
    let step = if tab.reader.display_mode == DisplayMode::TwoPage {
        2
    } else {
        1
    };
    for first in (0..rects.len()).step_by(step) {
        let range = first..(first + step).min(rects.len());
        let top = range
            .clone()
            .filter_map(|i| rects[i])
            .map(|r| r.min.y)
            .fold(f32::INFINITY, f32::min);
        let bottom = range
            .clone()
            .filter_map(|i| rects[i])
            .map(|r| r.max.y)
            .fold(f32::NEG_INFINITY, f32::max);
        if top.is_finite() {
            rows.push(LayoutRow {
                top,
                bottom,
                pages: range,
            });
        }
    }
    PageLayout {
        rows,
        rects,
        content_size: vec2(content_width, y - PAGE_GAP + MARGIN),
    }
}

#[derive(Debug, Clone, Copy)]
pub struct PagePoint {
    pub page: usize,
    pub point: (f32, f32),
}

pub struct ReaderResponse {
    pub pages: Vec<PageView>,
    pub canvas: Rect,
    pub hover: Option<PagePoint>,
    pub click: Option<PagePoint>,
    pub double_click: Option<PagePoint>,
    pub triple_click: Option<PagePoint>,
    /// Text drags can cross pages; drawing tools still use drag_current.
    pub text_drag_current: Option<PagePoint>,
    pub secondary_click: Option<PagePoint>,
    pub drag_start: Option<PagePoint>,
    /// While dragging: the pointer mapped onto the drag's starting page.
    pub drag_current: Option<PagePoint>,
    pub drag_stopped: bool,
    pub response: Option<egui::Response>,
}

impl ReaderResponse {
    pub fn page(&self, index: usize) -> Option<&PageView> {
        self.pages.iter().find(|view| view.index == index)
    }
}

pub fn show(ui: &mut Ui, tab: &mut DocumentTab, renderer: &mut RenderService) -> ReaderResponse {
    show_pane(ui, tab, renderer, 0)
}

pub fn show_pane(
    ui: &mut Ui,
    tab: &mut DocumentTab,
    renderer: &mut RenderService,
    pane: u8,
) -> ReaderResponse {
    tab.refresh_pages();
    let available = ui.available_size();
    let canvas = ui.available_rect_before_wrap();
    ui.painter().rect_filled(
        canvas,
        CornerRadius::ZERO,
        theme::workspace_color(tab.reader.theme),
    );

    let pointer_over = ui.rect_contains_pointer(canvas);
    let zoom_delta = if pointer_over {
        ui.ctx().input(|input| input.zoom_delta())
    } else {
        1.0
    };
    let mut scale = effective_scale(tab, available.x);
    if (zoom_delta - 1.0).abs() > f32::EPSILON {
        scale = (scale * zoom_delta).clamp(MIN_ZOOM, MAX_ZOOM);
        tab.reader.zoom = Zoom::Scale(scale);
    }
    tab.reader.effective_scale = scale;

    let page_layout = cached_layout(tab, scale, available.x);
    let mut scroll_area = egui::ScrollArea::both()
        .id_salt(("reader", tab.id, pane))
        .auto_shrink([false, false]);
    let navigation_target = tab.scroll_to_page;
    if let Some(target) = navigation_target {
        tab.navigation_anchor = Some(target);
    }
    if let Some(target) = tab.scroll_to_page.take()
        && let Some(Some(rect)) = page_layout.rects.get(target)
    {
        scroll_area = scroll_area.vertical_scroll_offset((rect.min.y - MARGIN / 2.0).max(0.0));
    }
    if let Some((page, point)) = tab.scroll_to_point.take()
        && let Some(Some(rect)) = page_layout.rects.get(page)
        && let Some(info) = tab.pages.get(page)
    {
        let (x, y) = info.geometry.to_display(point);
        let target = rect.min + vec2(x, y) * scale;
        scroll_area = scroll_area
            .vertical_scroll_offset((target.y - available.y * 0.4).max(0.0))
            .horizontal_scroll_offset((target.x - available.x * 0.5).max(0.0));
    }

    // Keep selecting beyond the visible area without losing the drag anchor.
    if tab.selection.is_some()
        && ui.input(|input| input.pointer.primary_down())
        && let Some(pointer) = ui.input(|input| input.pointer.interact_pos())
    {
        let edge = 28.0;
        let delta = if pointer.y < canvas.min.y + edge {
            -16.0
        } else if pointer.y > canvas.max.y - edge {
            16.0
        } else {
            0.0
        };
        if delta != 0.0 {
            scroll_area =
                scroll_area.vertical_scroll_offset((tab.scroll_offset.y + delta).max(0.0));
            ui.ctx().request_repaint();
        }
    }
    tab.prioritize_text(tab.reader.selected_page_index());
    let pixels_per_point = ui.ctx().pixels_per_point();
    let document_key = tab.document_key();
    let bytes = tab.pdf_data();
    let mut views = Vec::new();
    let mut all_views = Vec::new();
    let mut center_page = None;
    let mut response = None;

    let output = scroll_area.show_viewport(ui, |ui, viewport| {
        let (content_rect, content_response) =
            ui.allocate_exact_size(page_layout.content_size, Sense::click_and_drag());
        let origin = content_rect.min.to_vec2();
        let probe_y = viewport.min.y + viewport.height() * 0.35;
        let mut best_distance = f32::MAX;
        let expanded = viewport.expand2(vec2(0.0, viewport.height() * 0.5));
        for index in page_layout.visible_range(expanded) {
            let Some(rect) = page_layout.rects[index] else {
                continue;
            };
            let distance = if rect.y_range().contains(probe_y) {
                0.0
            } else {
                (rect.center().y - probe_y).abs()
            };
            if distance < best_distance {
                best_distance = distance;
                center_page = Some(index);
            }
            let screen_rect = rect.translate(origin);
            let view = PageView {
                index,
                rect: screen_rect,
                scale,
                geometry: tab.pages[index].geometry,
            };
            all_views.push(view);
            if !rect.intersects(viewport.expand2(vec2(0.0, viewport.height() * 0.5))) {
                continue;
            }
            let priority = if rect.intersects(viewport) {
                RenderPriority::Visible
            } else {
                RenderPriority::Prefetch
            };
            draw_page(
                ui,
                renderer,
                screen_rect,
                index,
                document_key,
                &bytes,
                pixels_per_point,
                priority,
            );
            if rect.intersects(viewport) {
                views.push(view);
            }
        }
        response = Some(content_response);
    });

    if navigation_target.is_none() && tab.scroll_offset != output.state.offset {
        tab.navigation_anchor = None;
    }
    tab.scroll_offset = output.state.offset;

    if tab.reader.display_mode != DisplayMode::SinglePage
        && tab.navigation_anchor.is_none()
        && let Some(page) = center_page
        && page != tab.reader.selected_page_index()
        && tab.scroll_to_page.is_none()
    {
        tab.prioritize_text(page);
        tab.reader.set_current_page(page);
        tab.go_to_page_text = (page + 1).to_string();
    }

    let mut result = ReaderResponse {
        pages: views,
        canvas,
        hover: None,
        click: None,
        double_click: None,
        triple_click: None,
        text_drag_current: None,
        secondary_click: None,
        drag_start: None,
        drag_current: None,
        drag_stopped: false,
        response: None,
    };
    if let Some(response) = response {
        let hit = |position: Pos2| -> Option<PagePoint> {
            all_views
                .iter()
                .find(|view| view.rect.contains(position))
                .map(|view| PagePoint {
                    page: view.index,
                    point: view.from_screen(position),
                })
        };
        let drag_page_id = egui::Id::new(("drag-page", tab.id, pane));
        if let Some(position) = response.hover_pos() {
            result.hover = hit(position);
        }
        if let Some(position) = response.interact_pointer_pos() {
            if response.triple_clicked() {
                result.triple_click = hit(position);
            } else if response.double_clicked() {
                result.double_click = hit(position);
            } else if response.clicked() {
                result.click = hit(position);
            }
            if response.secondary_clicked() {
                result.secondary_click = hit(position);
            }
            if response.drag_started_by(egui::PointerButton::Primary) {
                let origin = response
                    .ctx
                    .input(|input| input.pointer.press_origin())
                    .unwrap_or(position);
                result.drag_start = hit(origin);
                ui.ctx().data_mut(|data| {
                    data.insert_temp(drag_page_id, result.drag_start.map(|p| p.page))
                });
            }
            if response.dragged_by(egui::PointerButton::Primary) || response.drag_stopped() {
                result.text_drag_current = hit(position).or_else(|| {
                    all_views
                        .iter()
                        .min_by(|a, b| {
                            a.rect
                                .distance_to_pos(position)
                                .total_cmp(&b.rect.distance_to_pos(position))
                        })
                        .map(|view| PagePoint {
                            page: view.index,
                            point: view.from_screen(position.clamp(view.rect.min, view.rect.max)),
                        })
                });
                let page: Option<usize> =
                    ui.ctx().data(|data| data.get_temp(drag_page_id)).flatten();
                if let Some(view) =
                    page.and_then(|page| all_views.iter().find(|view| view.index == page))
                {
                    let clamped = position.clamp(view.rect.min, view.rect.max);
                    result.drag_current = Some(PagePoint {
                        page: view.index,
                        point: view.from_screen(clamped),
                    });
                }
            }
        }
        result.drag_stopped = response.drag_stopped();
        result.response = Some(response);
    }
    result
}

fn draw_page(
    ui: &Ui,
    renderer: &mut RenderService,
    rect: Rect,
    index: usize,
    document: crate::render::DocumentKey,
    bytes: &std::sync::Arc<Vec<u8>>,
    pixels_per_point: f32,
    priority: RenderPriority,
) {
    let painter = ui.painter();
    painter.add(
        Shadow {
            offset: [0, 3],
            blur: 12,
            spread: 0,
            color: theme::page_shadow(),
        }
        .as_shape(rect, CornerRadius::ZERO),
    );
    painter.rect_filled(rect, CornerRadius::ZERO, Color32::WHITE);
    let key = TextureKey {
        document,
        page: index,
        width_px: bucketed_width(rect.width() * pixels_per_point),
    };
    match renderer.texture_with_priority(key, bytes, priority) {
        Some(texture) => {
            painter.image(
                texture.id(),
                rect,
                Rect::from_min_max(Pos2::ZERO, pos2(1.0, 1.0)),
                Color32::WHITE,
            );
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
    painter.rect_stroke(
        rect,
        CornerRadius::ZERO,
        Stroke::new(0.5, Color32::from_black_alpha(60)),
        StrokeKind::Outside,
    );
}

#[cfg(test)]
mod performance_tests {
    use super::*;
    use std::hint::black_box;
    use std::time::Instant;

    #[test]
    #[ignore = "manual performance benchmark"]
    fn reader_layout_benchmark() {
        let bytes = pdf_core::testing::numbered_pdf(2000);
        let pdf_core::loader::OpenResult::Opened(session) =
            pdf_core::loader::open_bytes(bytes, std::path::PathBuf::from("benchmark.pdf")).unwrap()
        else {
            panic!("fixture")
        };
        let mut tab = DocumentTab::new(1, session);
        let start = Instant::now();
        for _ in 0..1000 {
            black_box(layout(black_box(&tab), 1.0, 1000.0));
        }
        eprintln!(
            "uncached layout 2000 pages / 1000 frames: {:?}",
            start.elapsed()
        );
        black_box(cached_layout(&mut tab, 1.0, 1000.0));
        let start = Instant::now();
        for frame in 0..1000 {
            let layout = cached_layout(black_box(&mut tab), 1.0, 1000.0);
            let viewport =
                Rect::from_min_size(pos2(0.0, frame as f32 * 400.0), vec2(1000.0, 800.0));
            black_box(layout.visible_range(viewport));
        }
        eprintln!(
            "cached layout and visible lookup / 1000 frames: {:?}",
            start.elapsed()
        );
    }
}

#[cfg(test)]
mod layout_tests {
    use super::*;
    #[test]
    fn visible_lookup_matches_full_scan_for_mixed_spreads() {
        let bytes = pdf_core::testing::numbered_pdf(11);
        let pdf_core::loader::OpenResult::Opened(session) =
            pdf_core::loader::open_bytes(bytes, "layout.pdf".into()).unwrap()
        else {
            panic!("fixture")
        };
        let mut tab = DocumentTab::new(1, session);
        for (i, info) in tab.pages.iter_mut().enumerate() {
            info.geometry.visible.y1 = 300.0 + i as f32 * 70.0;
        }
        for mode in DisplayMode::ALL {
            tab.reader.display_mode = mode;
            for scale in [0.2, 1.0, 4.0] {
                let layout = layout(&tab, scale, 800.0);
                for y in (0..12000).step_by(37) {
                    let viewport = Rect::from_min_size(pos2(0.0, y as f32), vec2(2000.0, 600.0));
                    let expected: Vec<_> = layout
                        .rects
                        .iter()
                        .enumerate()
                        .filter_map(|(i, r)| r.filter(|r| r.intersects(viewport)).map(|_| i))
                        .collect();
                    let actual: Vec<_> = layout
                        .visible_range(viewport)
                        .filter(|i| layout.rects[*i].is_some_and(|r| r.intersects(viewport)))
                        .collect();
                    assert_eq!(actual, expected);
                }
            }
        }
    }
}
