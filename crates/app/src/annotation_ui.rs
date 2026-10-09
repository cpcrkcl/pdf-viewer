//! Annotation tools, page interaction, overlays and the annotation navigator.

use egui::{Color32, CornerRadius, CursorIcon, Painter, Pos2, Rect, RichText, Shape, Stroke, StrokeKind, Ui, vec2};
use lopdf::Document as LoDocument;
use pdf_core::CoreResult;
use pdf_core::annotations::{
    self, AnnotationId, AnnotationInfo, AnnotationKind, LineWidth, MarkupKind, ShapeKind, SignatureSize, StampPreset,
    palette,
};
use pdf_core::appearance::Rgba;
use pdf_core::geometry::PdfBox;
use uuid::Uuid;

use crate::document_tab::{DocumentTab, Tool};
use crate::reader_view::{PageView, ReaderResponse};
use crate::theme::mocha;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum AnnotationTool {
    Select,
    Highlight,
    Underline,
    Strikethrough,
    Freehand,
    Eraser,
    TextNote,
    Rectangle,
    Oval,
    Line,
    Arrow,
    Stamp,
    Signature,
}

impl AnnotationTool {
    pub const ALL: [Self; 13] = [
        Self::Select,
        Self::Highlight,
        Self::Underline,
        Self::Strikethrough,
        Self::Freehand,
        Self::Eraser,
        Self::TextNote,
        Self::Rectangle,
        Self::Oval,
        Self::Line,
        Self::Arrow,
        Self::Stamp,
        Self::Signature,
    ];

    pub fn title(self) -> &'static str {
        match self {
            Self::Select => "Select",
            Self::Highlight => "Highlight",
            Self::Underline => "Underline",
            Self::Strikethrough => "Strikethrough",
            Self::Freehand => "Freehand",
            Self::Eraser => "Ink Eraser",
            Self::TextNote => "Text Note",
            Self::Rectangle => "Rectangle",
            Self::Oval => "Oval",
            Self::Line => "Line",
            Self::Arrow => "Arrow",
            Self::Stamp => "Stamp",
            Self::Signature => "Visual Signature",
        }
    }

    fn glyph(self) -> &'static str {
        match self {
            Self::Select => "⬉",
            Self::Highlight => "H",
            Self::Underline => "U",
            Self::Strikethrough => "S",
            Self::Freehand => "✏",
            Self::Eraser => "⌫",
            Self::TextNote => "🗊",
            Self::Rectangle => "▭",
            Self::Oval => "○",
            Self::Line => "╱",
            Self::Arrow => "↗",
            Self::Stamp => "★",
            Self::Signature => "✍",
        }
    }

    pub fn requires_text_selection(self) -> bool {
        matches!(self, Self::Highlight | Self::Underline | Self::Strikethrough)
    }

    fn markup(self) -> Option<MarkupKind> {
        match self {
            Self::Highlight => Some(MarkupKind::Highlight),
            Self::Underline => Some(MarkupKind::Underline),
            Self::Strikethrough => Some(MarkupKind::Strikethrough),
            _ => None,
        }
    }

    fn shape(self) -> Option<ShapeKind> {
        match self {
            Self::Rectangle => Some(ShapeKind::Rectangle),
            Self::Oval => Some(ShapeKind::Oval),
            Self::Line => Some(ShapeKind::Line),
            Self::Arrow => Some(ShapeKind::Arrow),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StampChoice {
    Preset(StampPreset),
    Custom(Uuid),
}

#[derive(Debug, Clone, PartialEq)]
pub struct Selected {
    pub page: usize,
    pub info: AnnotationInfo,
}

#[derive(Debug, Clone)]
enum Drag {
    Ink { page: usize, points: Vec<(f32, f32)> },
    Erase { page: usize, points: Vec<(f32, f32)> },
    Shape { page: usize, start: (f32, f32), end: (f32, f32) },
    Move { page: usize, id: AnnotationId, origin: (f32, f32), current: (f32, f32), rect: PdfBox },
    Resize { page: usize, id: AnnotationId, rect: PdfBox, current: (f32, f32) },
}

pub struct AnnotationState {
    pub color: Rgba,
    pub line_width: LineWidth,
    pub stamp: StampChoice,
    pub signature: Option<Uuid>,
    pub signature_size: SignatureSize,
    pub selected: Option<Selected>,
    drag: Option<Drag>,
    pub index: Vec<Vec<AnnotationInfo>>,
    index_generation: Option<u64>,
}

impl Default for AnnotationState {
    fn default() -> Self {
        Self {
            color: palette::YELLOW,
            line_width: LineWidth::Standard,
            stamp: StampChoice::Preset(StampPreset::Approved),
            signature: None,
            signature_size: SignatureSize::Medium,
            selected: None,
            drag: None,
            index: Vec::new(),
            index_generation: None,
        }
    }
}

/// Requests the app has to fulfil (they need dialogs or shared libraries).
pub enum AnnotationRequest {
    None,
    Error(String),
    NewNote { page: usize, point: (f32, f32) },
    EditNote { page: usize, id: AnnotationId, contents: String },
    PlaceStamp { page: usize, point: (f32, f32), choice: StampChoice },
    PlaceSignature { page: usize, point: (f32, f32) },
    OpenSignatureLibrary,
    OpenStampLibrary,
}

impl DocumentTab {
    /// Refreshes the cached annotation index for the current revision.
    pub fn refresh_annotation_index(&mut self) {
        let generation = self.generation();
        if self.annotations.index_generation == Some(generation) {
            return;
        }
        self.annotations.index_generation = Some(generation);
        self.annotations.index = self
            .session
            .editor
            .parse()
            .map(|document| annotations::annotation_index(&document))
            .unwrap_or_default();
        // Keep the selection pointing at the same annotation if it survived.
        if let Some(selected) = &self.annotations.selected {
            let page = selected.page;
            let refreshed = self.annotations.index.get(page).and_then(|list| {
                list.iter()
                    .find(|info| match (info.owned, selected.info.owned) {
                        (Some(a), Some(b)) => a == b,
                        _ => info.object == selected.info.object,
                    })
                    .cloned()
            });
            self.annotations.selected = refreshed.map(|info| Selected { page, info });
        }
    }

    /// Commits an annotation change as one undoable revision.
    pub fn annotate(&mut self, body: impl FnOnce(&mut LoDocument) -> CoreResult<()>) -> Result<(), String> {
        if !self.session.security.allows_commenting() {
            return Err("This PDF's permissions don't allow adding or changing annotations.".into());
        }
        self.session.editor.mutate(body).map_err(|error| error.to_string())?;
        self.after_annotation_change();
        Ok(())
    }

    /// Annotation edits don't move text, so search results stay valid.
    pub fn after_annotation_change(&mut self) {
        self.refresh_pages();
        self.refresh_annotation_index();
    }
}

fn is_annotating(tab: &DocumentTab) -> Option<AnnotationTool> {
    match tab.tool {
        Tool::Annotate(tool) => Some(tool),
        _ => None,
    }
}

fn hit_test(tab: &DocumentTab, page: usize, point: (f32, f32)) -> Option<AnnotationInfo> {
    tab.annotations.index.get(page)?.iter().rev().find(|info| {
        if info.kind == AnnotationKind::Other {
            return false;
        }
        let slop = 4.0;
        if !info.rect.inset(-slop, -slop).contains(point) {
            return false;
        }
        match info.kind {
            AnnotationKind::Ink => info.ink.iter().any(|stroke| {
                stroke.windows(2).any(|segment| annotations::distance_to_segment(point, segment[0], segment[1]) <= 6.0)
            }),
            _ => true,
        }
    }).cloned()
}

fn resize_handle(view: &PageView, rect: &PdfBox) -> Rect {
    let screen = view.box_to_screen(rect);
    Rect::from_center_size(screen.right_bottom(), vec2(10.0, 10.0))
}

/// Handles pointer input for the active annotation tool.
pub fn handle(ctx: &egui::Context, tab: &mut DocumentTab, response: &ReaderResponse) -> AnnotationRequest {
    tab.refresh_annotation_index();
    let Some(tool) = is_annotating(tab) else { return AnnotationRequest::None };
    let color = tab.annotations.color;
    let width = tab.annotations.line_width;

    if let Some(hover) = response.hover {
        let cursor = match tool {
            AnnotationTool::Select => {
                let over_handle = tab.annotations.selected.as_ref().and_then(|selected| {
                    let view = response.page(selected.page)?;
                    let pointer = ctx.pointer_hover_pos()?;
                    (selected.info.owned.is_some() && resize_handle(view, &selected.info.rect).contains(pointer)).then_some(())
                });
                if over_handle.is_some() {
                    CursorIcon::ResizeNwSe
                } else if hit_test(tab, hover.page, hover.point).is_some_and(|info| info.owned.is_some()) {
                    CursorIcon::Grab
                } else {
                    CursorIcon::Default
                }
            }
            AnnotationTool::Highlight | AnnotationTool::Underline | AnnotationTool::Strikethrough => CursorIcon::Text,
            _ => CursorIcon::Crosshair,
        };
        ctx.set_cursor_icon(cursor);
    }

    // Starting a drag.
    if let Some(start) = response.drag_start {
        match tool {
            AnnotationTool::Select => {
                let pointer = ctx.input(|input| input.pointer.press_origin());
                let selected = tab.annotations.selected.clone();
                let on_handle = selected.as_ref().is_some_and(|selected| {
                    selected.page == start.page
                        && selected.info.owned.is_some()
                        && response
                            .page(start.page)
                            .zip(pointer)
                            .is_some_and(|(view, pointer)| resize_handle(view, &selected.info.rect).contains(pointer))
                });
                if on_handle && let Some(selected) = selected {
                    tab.annotations.drag = Some(Drag::Resize {
                        page: start.page,
                        id: selected.info.owned.unwrap(),
                        rect: selected.info.rect,
                        current: start.point,
                    });
                } else if let Some(info) = hit_test(tab, start.page, start.point) {
                    tab.annotations.selected = Some(Selected { page: start.page, info: info.clone() });
                    if let Some(id) = info.owned {
                        tab.annotations.drag = Some(Drag::Move {
                            page: start.page,
                            id,
                            origin: start.point,
                            current: start.point,
                            rect: info.rect,
                        });
                    }
                }
            }
            AnnotationTool::Freehand => tab.annotations.drag = Some(Drag::Ink { page: start.page, points: vec![start.point] }),
            AnnotationTool::Eraser => tab.annotations.drag = Some(Drag::Erase { page: start.page, points: vec![start.point] }),
            AnnotationTool::Rectangle | AnnotationTool::Oval | AnnotationTool::Line | AnnotationTool::Arrow => {
                tab.annotations.drag = Some(Drag::Shape { page: start.page, start: start.point, end: start.point })
            }
            AnnotationTool::Highlight | AnnotationTool::Underline | AnnotationTool::Strikethrough => {
                tab.selection = None;
                if let Some(text) = tab.text_index(ctx)
                    && let Some(index) = text.get(start.page).and_then(|page| page.char_at(start.point))
                {
                    tab.selection = Some(crate::document_tab::TextSelection { page: start.page, anchor: index, focus: index });
                }
            }
            _ => {}
        }
    }

    // Continuing a drag.
    if let Some(current) = response.drag_current {
        match &mut tab.annotations.drag {
            Some(Drag::Ink { page, points } | Drag::Erase { page, points }) if *page == current.page => {
                if points.last().is_none_or(|last| (last.0 - current.point.0).hypot(last.1 - current.point.1) > 0.75) {
                    points.push(current.point);
                }
            }
            Some(Drag::Shape { page, end, .. }) if *page == current.page => *end = current.point,
            Some(Drag::Move { page, current: position, .. } | Drag::Resize { page, current: position, .. }) if *page == current.page => {
                *position = current.point
            }
            _ => {}
        }
        if tool.requires_text_selection()
            && let Some(text) = tab.text_index(ctx)
            && let Some(selection) = tab.selection.as_mut()
            && selection.page == current.page
            && let Some(index) = text.get(current.page).and_then(|page| page.char_at(current.point))
        {
            selection.focus = index;
        }
    }

    // Finishing a drag.
    if response.drag_stopped {
        let mut result = Ok(());
        match tab.annotations.drag.take() {
            Some(Drag::Ink { page, points }) if points.len() >= 2 => {
                result = tab.annotate(|document| annotations::add_ink(document, page, &points, color, width).map(|_| ()));
            }
            Some(Drag::Erase { page, points }) => {
                let radius = 6.0 / response.page(page).map_or(1.0, |view| view.scale).max(0.1);
                result = tab.annotate(|document| annotations::erase_ink(document, page, &points, radius.max(3.0)).map(|_| ()));
            }
            Some(Drag::Shape { page, start, end }) => {
                if let Some(kind) = tool.shape() {
                    let moved = (end.0 - start.0).hypot(end.1 - start.1) >= 4.0;
                    if moved {
                        result = tab.annotate(|document| annotations::add_shape(document, kind, page, start, end, color, width).map(|_| ()));
                    }
                }
            }
            Some(Drag::Move { page, id, origin, current, .. }) => {
                let (dx, dy) = (current.0 - origin.0, current.1 - origin.1);
                if dx.abs() > 0.5 || dy.abs() > 0.5 {
                    result = tab.annotate(|document| annotations::move_annotation(document, page, id, dx, dy));
                }
            }
            Some(Drag::Resize { page, id, rect, current }) => {
                let target = resized_rect(&rect, current, response.page(page));
                result = tab.annotate(|document| annotations::set_annotation_rect(document, page, id, target));
            }
            _ => {}
        }
        if let Some(markup) = tool.markup() {
            result = commit_markup(ctx, tab, markup);
        }
        if let Err(message) = result {
            return AnnotationRequest::Error(message);
        }
    }

    // Clicks.
    if let Some(click) = response.click {
        match tool {
            AnnotationTool::Select => {
                tab.annotations.selected = hit_test(tab, click.page, click.point).map(|info| Selected { page: click.page, info });
            }
            AnnotationTool::TextNote => return AnnotationRequest::NewNote { page: click.page, point: click.point },
            AnnotationTool::Stamp => {
                return AnnotationRequest::PlaceStamp { page: click.page, point: click.point, choice: tab.annotations.stamp };
            }
            AnnotationTool::Signature => return AnnotationRequest::PlaceSignature { page: click.page, point: click.point },
            _ => {}
        }
    }
    if let Some(double) = response.double_click
        && tool == AnnotationTool::Select
        && let Some(info) = hit_test(tab, double.page, double.point)
        && info.kind == AnnotationKind::TextNote
        && let Some(id) = info.owned
    {
        return AnnotationRequest::EditNote { page: double.page, id, contents: info.contents.unwrap_or_default() };
    }
    AnnotationRequest::None
}

fn resized_rect(rect: &PdfBox, pointer: (f32, f32), view: Option<&PageView>) -> PdfBox {
    // Drag the displayed bottom-right corner; the opposite corner stays put.
    let Some(view) = view else { return *rect };
    let ((min_x, min_y), _) = view.geometry.box_to_display(rect);
    let anchor = view.geometry.from_display((min_x, min_y));
    PdfBox::from_points(anchor, pointer)
}

/// Turns the current text selection into a markup annotation.
pub fn commit_markup(ctx: &egui::Context, tab: &mut DocumentTab, markup: MarkupKind) -> Result<(), String> {
    let Some(selection) = tab.selection.clone() else { return Ok(()) };
    let Some(text) = tab.text_index(ctx) else { return Ok(()) };
    let Some(page_text) = text.get(selection.page) else { return Ok(()) };
    let (start, end) = selection.range();
    let boxes = page_text.line_boxes(start, end);
    if boxes.is_empty() {
        return Ok(());
    }
    let color = tab.annotations.color;
    let page = selection.page;
    tab.annotate(|document| annotations::add_text_markup(document, markup, &[(page, boxes)], color).map(|_| ()))?;
    tab.selection = None;
    Ok(())
}

pub fn delete_selected(tab: &mut DocumentTab) -> Result<(), String> {
    let Some(selected) = tab.annotations.selected.clone() else { return Ok(()) };
    let Some(id) = selected.info.owned else {
        return Err("This annotation was not created by PDFViewer and is read-only.".into());
    };
    tab.annotate(|document| annotations::delete_annotation(document, selected.page, id))?;
    tab.annotations.selected = None;
    Ok(())
}

/// Selection outline, resize handle and live drag previews.
pub fn paint_overlays(painter: &Painter, tab: &DocumentTab, response: &ReaderResponse) {
    let color = tab.annotations.color;
    let preview = Color32::from_rgba_unmultiplied(
        (color.r * 255.0) as u8,
        (color.g * 255.0) as u8,
        (color.b * 255.0) as u8,
        220,
    );
    if let Some(selected) = &tab.annotations.selected
        && let Some(view) = response.page(selected.page)
    {
        let mut rect = selected.info.rect;
        if let Some(Drag::Move { origin, current, .. }) = &tab.annotations.drag {
            rect = rect.offset(current.0 - origin.0, current.1 - origin.1);
        }
        if let Some(Drag::Resize { rect: original, current, .. }) = &tab.annotations.drag {
            rect = resized_rect(original, *current, Some(view));
        }
        let screen = view.box_to_screen(&rect).expand(3.0);
        let stroke_color = if selected.info.owned.is_some() { mocha::BLUE } else { mocha::OVERLAY0 };
        painter.add(Shape::dashed_line(
            &[screen.left_top(), screen.right_top(), screen.right_bottom(), screen.left_bottom(), screen.left_top()],
            Stroke::new(1.5, stroke_color),
            5.0,
            3.0,
        ));
        if selected.info.owned.is_some() {
            let handle = Rect::from_center_size(screen.right_bottom(), vec2(10.0, 10.0));
            painter.rect_filled(handle, CornerRadius::same(2), mocha::BLUE);
        }
    }
    match &tab.annotations.drag {
        Some(Drag::Ink { page, points }) => {
            if let Some(view) = response.page(*page) {
                let stroke = Stroke::new(tab.annotations.line_width.points() * view.scale, preview);
                let screen: Vec<Pos2> = points.iter().map(|point| view.to_screen(*point)).collect();
                painter.add(Shape::line(screen, stroke));
            }
        }
        Some(Drag::Erase { page, points }) => {
            if let Some(view) = response.page(*page) {
                for point in points {
                    painter.circle_stroke(view.to_screen(*point), 6.0, Stroke::new(1.0, mocha::RED));
                }
            }
        }
        Some(Drag::Shape { page, start, end }) => {
            if let (Some(view), Some(kind)) = (response.page(*page), is_annotating(tab).and_then(AnnotationTool::shape)) {
                let stroke = Stroke::new(tab.annotations.line_width.points() * view.scale, preview);
                let (a, b) = (view.to_screen(*start), view.to_screen(*end));
                match kind {
                    ShapeKind::Rectangle => {
                        painter.rect_stroke(Rect::from_two_pos(a, b), CornerRadius::ZERO, stroke, StrokeKind::Middle);
                    }
                    ShapeKind::Oval => {
                        let rect = Rect::from_two_pos(a, b);
                        painter.add(Shape::ellipse_stroke(rect.center(), rect.size() / 2.0, stroke));
                    }
                    ShapeKind::Line => {
                        painter.line_segment([a, b], stroke);
                    }
                    ShapeKind::Arrow => {
                        painter.arrow(a, b - a, stroke);
                    }
                }
            }
        }
        _ => {}
    }
}

/// The annotation tool strip shown while annotating.
pub fn toolbar(ui: &mut Ui, tab: &mut DocumentTab, signatures: &[pdf_core::signatures::StoredSignature], stamps: &[pdf_core::signatures::StoredSignature]) -> AnnotationRequest {
    let mut request = AnnotationRequest::None;
    let current = is_annotating(tab);
    ui.horizontal_wrapped(|ui| {
        for tool in AnnotationTool::ALL {
            let selected = current == Some(tool);
            let response = ui
                .selectable_label(selected, RichText::new(tool.glyph()).size(15.0))
                .on_hover_text(tool.title());
            if response.clicked() {
                tab.tool = Tool::Annotate(tool);
                tab.annotations.drag = None;
                if tool != AnnotationTool::Select {
                    tab.annotations.selected = None;
                }
                if let Some(markup) = tool.markup()
                    && tab.selection.is_some()
                {
                    let ctx = ui.ctx().clone();
                    if let Err(message) = commit_markup(&ctx, tab, markup) {
                        request = AnnotationRequest::Error(message);
                    }
                }
            }
        }
        ui.separator();
        // Color: palette plus a custom picker.
        let mut chosen = None;
        for (name, color) in palette::ALL {
            let fill = to_color32(color);
            let (rect, response) = ui.allocate_exact_size(vec2(16.0, 16.0), egui::Sense::click());
            ui.painter().circle_filled(rect.center(), 7.0, fill);
            if same_rgb(tab.annotations.color, color) {
                ui.painter().circle_stroke(rect.center(), 8.5, Stroke::new(1.5, mocha::TEXT));
            }
            if response.on_hover_text(name).clicked() {
                chosen = Some(color);
            }
        }
        let mut rgb = [tab.annotations.color.r, tab.annotations.color.g, tab.annotations.color.b];
        if ui.color_edit_button_rgb(&mut rgb).on_hover_text("Custom Color").changed() {
            chosen = Some(Rgba::new(rgb[0], rgb[1], rgb[2], 1.0));
        }
        if let Some(color) = chosen {
            tab.annotations.color = color;
            if let Some(selected) = tab.annotations.selected.clone()
                && let Some(id) = selected.info.owned
                && selected.info.kind.has_color()
                && let Err(message) = tab.annotate(|document| annotations::set_color(document, selected.page, id, color))
            {
                request = AnnotationRequest::Error(message);
            }
        }
        ui.separator();
        egui::ComboBox::from_id_salt("line-width")
            .selected_text(tab.annotations.line_width.title())
            .width(96.0)
            .show_ui(ui, |ui| {
                for width in LineWidth::ALL {
                    if ui.selectable_value(&mut tab.annotations.line_width, width, width.title()).clicked()
                        && let Some(selected) = tab.annotations.selected.clone()
                        && let Some(id) = selected.info.owned
                        && selected.info.kind.has_line_width()
                        && let Err(message) = tab.annotate(|document| annotations::set_line_width(document, selected.page, id, width))
                    {
                        request = AnnotationRequest::Error(message);
                    }
                }
            });
        match current {
            Some(AnnotationTool::Stamp) => {
                let label = match tab.annotations.stamp {
                    StampChoice::Preset(preset) => preset.title().to_owned(),
                    StampChoice::Custom(id) => stamps
                        .iter()
                        .find(|stamp| stamp.id == id)
                        .map(|stamp| stamp.display_name.clone())
                        .unwrap_or_else(|| "Custom".into()),
                };
                egui::ComboBox::from_id_salt("stamp").selected_text(label).show_ui(ui, |ui| {
                    for preset in StampPreset::ALL {
                        ui.selectable_value(&mut tab.annotations.stamp, StampChoice::Preset(preset), preset.title());
                    }
                    if !stamps.is_empty() {
                        ui.separator();
                    }
                    for stamp in stamps {
                        ui.selectable_value(&mut tab.annotations.stamp, StampChoice::Custom(stamp.id), &stamp.display_name);
                    }
                });
                if ui.button("Stamp Library…").clicked() {
                    request = AnnotationRequest::OpenStampLibrary;
                }
            }
            Some(AnnotationTool::Signature) => {
                let label = tab
                    .annotations
                    .signature
                    .and_then(|id| signatures.iter().find(|signature| signature.id == id))
                    .map(|signature| signature.display_name.clone())
                    .unwrap_or_else(|| "Choose…".into());
                if ui.button(format!("Signature: {label}")).clicked() {
                    request = AnnotationRequest::OpenSignatureLibrary;
                }
                size_picker(ui, tab, &mut request);
            }
            _ => {}
        }
        if let Some(selected) = tab.annotations.selected.clone() {
            ui.separator();
            selection_controls(ui, tab, &selected, &mut request);
        }
    });
    request
}

fn size_picker(ui: &mut Ui, tab: &mut DocumentTab, request: &mut AnnotationRequest) {
    egui::ComboBox::from_id_salt("signature-size")
        .selected_text(tab.annotations.signature_size.title())
        .width(80.0)
        .show_ui(ui, |ui| {
            for size in SignatureSize::ALL {
                if ui.selectable_value(&mut tab.annotations.signature_size, size, size.title()).clicked()
                    && let Some(selected) = tab.annotations.selected.clone()
                    && let Some(id) = selected.info.owned
                    && matches!(selected.info.kind, AnnotationKind::Signature)
                    && let Err(message) = tab.annotate(|document| annotations::set_image_stamp_size(document, selected.page, id, size))
                {
                    *request = AnnotationRequest::Error(message);
                }
            }
        });
}

fn selection_controls(ui: &mut Ui, tab: &mut DocumentTab, selected: &Selected, request: &mut AnnotationRequest) {
    let Some(id) = selected.info.owned else {
        ui.weak(format!("{} · read-only", selected.info.kind.title()));
        return;
    };
    ui.label(RichText::new(selected.info.kind.title()).strong());
    let page = selected.page;
    let mut result = Ok(());
    if ui.small_button("−").on_hover_text("Shrink").clicked() {
        result = tab.annotate(|document| annotations::resize_annotation(document, page, id, 0.9));
    }
    if ui.small_button("+").on_hover_text("Enlarge").clicked() {
        result = tab.annotate(|document| annotations::resize_annotation(document, page, id, 1.1));
    }
    if selected.info.has_image {
        if ui.small_button("⟲").on_hover_text("Rotate Left").clicked() {
            result = tab.annotate(|document| annotations::rotate_image_stamp(document, page, id, false));
        }
        if ui.small_button("⟳").on_hover_text("Rotate Right").clicked() {
            result = tab.annotate(|document| annotations::rotate_image_stamp(document, page, id, true));
        }
        if selected.info.kind == AnnotationKind::Signature {
            size_picker(ui, tab, request);
        }
    }
    if selected.info.kind == AnnotationKind::TextNote && ui.small_button("Edit Note…").clicked() {
        *request = AnnotationRequest::EditNote { page, id, contents: selected.info.contents.clone().unwrap_or_default() };
    }
    if ui.small_button(RichText::new("Delete").color(mocha::RED)).clicked() {
        result = delete_selected(tab);
    }
    if let Err(message) = result {
        *request = AnnotationRequest::Error(message);
    }
}

pub fn to_color32(color: Rgba) -> Color32 {
    Color32::from_rgb((color.r * 255.0) as u8, (color.g * 255.0) as u8, (color.b * 255.0) as u8)
}

fn same_rgb(a: Rgba, b: Rgba) -> bool {
    (a.r - b.r).abs() < 0.01 && (a.g - b.g).abs() < 0.01 && (a.b - b.b).abs() < 0.01
}

/// Sidebar list of PDFViewer-owned annotations.
pub fn annotation_list(ui: &mut Ui, tab: &mut DocumentTab) {
    tab.refresh_annotation_index();
    let owned: Vec<AnnotationInfo> = tab.annotations.index.iter().flatten().filter(|info| info.owned.is_some()).cloned().collect();
    if owned.is_empty() {
        ui.weak("No PDFViewer annotations yet. Choose Annotate in the toolbar to add some.");
        return;
    }
    let mut navigate = None;
    let mut delete = None;
    egui::ScrollArea::vertical()
        .id_salt(("annotations", tab.id))
        .auto_shrink([false, false])
        .show(ui, |ui| {
            for info in owned {
                let selected = tab.annotations.selected.as_ref().is_some_and(|s| s.info.owned == info.owned);
                ui.horizontal(|ui| {
                    if let Some(color) = info.color {
                        let (rect, _) = ui.allocate_exact_size(vec2(10.0, 10.0), egui::Sense::hover());
                        ui.painter().circle_filled(rect.center(), 4.0, to_color32(color));
                    }
                    let text = format!("p. {} · {}", tab.page_label(info.page), info.label);
                    if ui.selectable_label(selected, text).clicked() {
                        navigate = Some(info.clone());
                    }
                    ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                        if ui.small_button("✕").on_hover_text("Delete").clicked() {
                            delete = Some(info.clone());
                        }
                    });
                });
            }
        });
    if let Some(info) = navigate {
        let page = info.page;
        tab.navigate_to(page);
        tab.scroll_to_point = Some((page, info.rect.center()));
        tab.scroll_to_page = None;
        tab.tool = Tool::Annotate(AnnotationTool::Select);
        tab.annotations.selected = Some(Selected { page, info });
    }
    if let Some(info) = delete {
        tab.annotations.selected = Some(Selected { page: info.page, info });
        let _ = delete_selected(tab);
    }
}

/// Places a signature from the library at `point`.
pub fn place_image(
    tab: &mut DocumentTab,
    page: usize,
    point: (f32, f32),
    data: &[u8],
    size: SignatureSize,
    custom_stamp_name: Option<&str>,
) -> Result<(), String> {
    let mut placed = None;
    tab.annotate(|document| {
        placed = Some(annotations::add_image_stamp(document, page, point, data, size, custom_stamp_name)?);
        Ok(())
    })?;
    if let Some(id) = placed {
        tab.refresh_annotation_index();
        let info = tab.annotations.index.get(page).and_then(|list| list.iter().find(|info| info.owned == Some(id)).cloned());
        tab.annotations.selected = info.map(|info| Selected { page, info });
        tab.tool = Tool::Annotate(AnnotationTool::Select);
    }
    Ok(())
}
