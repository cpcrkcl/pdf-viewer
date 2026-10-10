//! Vector toolbar icons drawn with the painter, so they stay crisp at any
//! scale and don't depend on which symbol fonts the system has.

use egui::epaint::{CubicBezierShape, PathShape, PathStroke};
use egui::{Align2, Color32, CornerRadius, FontId, Pos2, Rect, Response, Sense, Stroke, StrokeKind, Ui, Vec2, pos2, vec2};

use crate::theme;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Icon {
    Sidebar,
    Back,
    Forward,
    Previous,
    Next,
    ZoomIn,
    ZoomOut,
    Search,
    Thumbnails,
    Contents,
    Bookmark,
    Annotations,
    Close,
    ChevronUp,
    ChevronDown,
    Pointer,
    Highlight,
    Underline,
    Strikethrough,
    Pen,
    Eraser,
    Note,
    Rectangle,
    Oval,
    Line,
    Arrow,
    Stamp,
    Signature,
    Lock,
    Document,
}

/// Paints `icon` centered in `rect` (designed on a 16-point grid).
pub fn paint(painter: &egui::Painter, rect: Rect, icon: Icon, color: Color32) {
    let s = rect.width().min(rect.height()) / 16.0;
    let o = rect.center() - vec2(8.0, 8.0) * s;
    let p = |x: f32, y: f32| o + vec2(x, y) * s;
    let stroke = Stroke::new(1.4 * s.max(1.0), color);
    let line = |a: Pos2, b: Pos2| {
        painter.line_segment([a, b], stroke);
    };
    let poly = |points: Vec<Pos2>, closed: bool| {
        let shape = if closed {
            PathShape::closed_line(points, stroke)
        } else {
            PathShape::line(points, PathStroke::new(stroke.width, color))
        };
        painter.add(shape);
    };
    let curve = |a: Pos2, b: Pos2, c: Pos2, d: Pos2| {
        painter.add(CubicBezierShape::from_points_stroke([a, b, c, d], false, Color32::TRANSPARENT, stroke));
    };
    let r = |x0: f32, y0: f32, x1: f32, y1: f32| Rect::from_min_max(p(x0, y0), p(x1, y1));
    let glyph = |text: &str, size: f32| {
        painter.text(p(8.0, 7.2), Align2::CENTER_CENTER, text, FontId::proportional(size * s), color);
    };
    match icon {
        Icon::Sidebar => {
            painter.rect_stroke(r(1.5, 2.5, 14.5, 13.5), CornerRadius::same(2), stroke, StrokeKind::Middle);
            line(p(6.0, 2.5), p(6.0, 13.5));
            line(p(3.0, 5.0), p(4.5, 5.0));
            line(p(3.0, 7.0), p(4.5, 7.0));
        }
        Icon::Back | Icon::Previous => poly(vec![p(10.0, 3.0), p(5.0, 8.0), p(10.0, 13.0)], false),
        Icon::Forward | Icon::Next => poly(vec![p(6.0, 3.0), p(11.0, 8.0), p(6.0, 13.0)], false),
        Icon::ChevronUp => poly(vec![p(4.0, 10.0), p(8.0, 6.0), p(12.0, 10.0)], false),
        Icon::ChevronDown => poly(vec![p(4.0, 6.0), p(8.0, 10.0), p(12.0, 6.0)], false),
        Icon::ZoomIn => {
            line(p(3.0, 8.0), p(13.0, 8.0));
            line(p(8.0, 3.0), p(8.0, 13.0));
        }
        Icon::ZoomOut => line(p(3.0, 8.0), p(13.0, 8.0)),
        Icon::Search => {
            painter.circle_stroke(p(7.0, 7.0), 4.5 * s, stroke);
            line(p(10.3, 10.3), p(14.0, 14.0));
        }
        Icon::Thumbnails => {
            for (x, y) in [(2.0, 2.0), (9.0, 2.0), (2.0, 9.0), (9.0, 9.0)] {
                painter.rect_stroke(r(x, y, x + 5.0, y + 5.0), CornerRadius::same(1), stroke, StrokeKind::Middle);
            }
        }
        Icon::Contents => {
            for (indent, y) in [(2.0, 3.5), (5.0, 6.5), (5.0, 9.5), (2.0, 12.5)] {
                painter.circle_filled(p(indent, y), 0.9 * s, color);
                line(p(indent + 2.5, y), p(14.0, y));
            }
        }
        Icon::Bookmark => poly(vec![p(4.0, 2.0), p(12.0, 2.0), p(12.0, 14.0), p(8.0, 10.5), p(4.0, 14.0)], true),
        Icon::Annotations => {
            poly(vec![p(2.0, 3.0), p(14.0, 3.0), p(14.0, 11.0), p(7.0, 11.0), p(4.0, 14.0), p(4.0, 11.0), p(2.0, 11.0)], true);
            line(p(5.0, 6.0), p(11.0, 6.0));
            line(p(5.0, 8.5), p(9.0, 8.5));
        }
        Icon::Close => {
            line(p(4.0, 4.0), p(12.0, 12.0));
            line(p(12.0, 4.0), p(4.0, 12.0));
        }
        Icon::Pointer => {
            let points = vec![p(4.0, 2.0), p(4.0, 13.0), p(6.8, 10.4), p(8.8, 14.5), p(10.6, 13.7), p(8.6, 9.6), p(12.2, 9.6)];
            poly(points, true);
        }
        Icon::Highlight => {
            painter.rect_filled(r(1.5, 9.5, 14.5, 14.0), CornerRadius::same(1), color.gamma_multiply(0.45));
            painter.text(p(8.0, 7.0), Align2::CENTER_CENTER, "A", FontId::proportional(11.0 * s), color);
        }
        Icon::Underline => {
            painter.text(p(8.0, 6.5), Align2::CENTER_CENTER, "A", FontId::proportional(11.0 * s), color);
            line(p(3.0, 13.5), p(13.0, 13.5));
        }
        Icon::Strikethrough => {
            glyph("A", 12.0);
            line(p(2.5, 8.5), p(13.5, 8.5));
        }
        Icon::Pen => {
            poly(vec![p(3.0, 13.0), p(3.5, 10.5), p(11.0, 3.0), p(13.0, 5.0), p(5.5, 12.5)], true);
            line(p(9.5, 4.5), p(11.5, 6.5));
        }
        Icon::Eraser => {
            poly(vec![p(2.5, 10.5), p(9.0, 3.5), p(13.5, 8.0), p(8.5, 13.5), p(5.0, 13.5)], true);
            line(p(5.5, 7.0), p(10.5, 11.5));
            line(p(8.5, 13.5), p(14.0, 13.5));
        }
        Icon::Note => {
            poly(vec![p(2.5, 2.5), p(13.5, 2.5), p(13.5, 9.5), p(9.5, 13.5), p(2.5, 13.5)], true);
            poly(vec![p(13.5, 9.5), p(9.5, 9.5), p(9.5, 13.5)], false);
        }
        Icon::Rectangle => {
            painter.rect_stroke(r(2.0, 3.5, 14.0, 12.5), CornerRadius::same(1), stroke, StrokeKind::Middle);
        }
        Icon::Oval => {
            painter.add(egui::epaint::EllipseShape::stroke(p(8.0, 8.0), vec2(6.0, 4.6) * s, stroke));
        }
        Icon::Line => line(p(3.0, 13.0), p(13.0, 3.0)),
        Icon::Arrow => {
            line(p(3.0, 13.0), p(13.0, 3.0));
            poly(vec![p(7.5, 3.0), p(13.0, 3.0), p(13.0, 8.5)], false);
        }
        Icon::Stamp => {
            painter.rect_stroke(r(2.0, 10.0, 14.0, 13.0), CornerRadius::same(1), stroke, StrokeKind::Middle);
            poly(vec![p(5.0, 10.0), p(6.5, 6.5), p(9.5, 6.5), p(11.0, 10.0)], false);
            painter.circle_stroke(p(8.0, 4.2), 2.2 * s, stroke);
        }
        Icon::Signature => {
            curve(p(2.0, 10.0), p(4.0, 2.0), p(6.0, 2.5), p(6.0, 9.0));
            curve(p(6.0, 9.0), p(7.0, 5.0), p(9.0, 5.0), p(10.0, 9.0));
            curve(p(10.0, 9.0), p(11.0, 7.0), p(12.5, 7.0), p(14.0, 8.5));
            line(p(2.0, 13.5), p(14.0, 13.5));
        }
        Icon::Lock => {
            painter.rect_stroke(r(3.0, 7.0, 13.0, 14.0), CornerRadius::same(2), stroke, StrokeKind::Middle);
            poly(vec![p(5.5, 7.0), p(5.5, 4.5), p(6.5, 2.8), p(9.5, 2.8), p(10.5, 4.5), p(10.5, 7.0)], false);
        }
        Icon::Document => {
            poly(vec![p(3.5, 1.5), p(10.0, 1.5), p(13.0, 4.5), p(13.0, 14.5), p(3.5, 14.5)], true);
            poly(vec![p(10.0, 1.5), p(10.0, 4.5), p(13.0, 4.5)], false);
        }
    }
}

/// A borderless icon button that shows its background only when hovered or
/// selected; selection uses the accent.
pub fn button(ui: &mut Ui, icon: Icon, selected: bool, tooltip: &str) -> Response {
    sized_button(ui, icon, selected, tooltip, vec2(28.0, 26.0))
}

pub fn sized_button(ui: &mut Ui, icon: Icon, selected: bool, tooltip: &str, size: Vec2) -> Response {
    let enabled = ui.is_enabled();
    let (rect, response) = ui.allocate_exact_size(size, Sense::click());
    let colors = theme::colors();
    if ui.is_rect_visible(rect) {
        let fill = if selected {
            colors.accent.gamma_multiply(if colors.dark { 0.22 } else { 0.14 })
        } else if response.is_pointer_button_down_on() {
            colors.pressed
        } else if response.hovered() && enabled {
            colors.hover
        } else {
            Color32::TRANSPARENT
        };
        ui.painter().rect_filled(rect, CornerRadius::same(6), fill);
        let color = if !enabled {
            colors.faint
        } else if selected {
            colors.accent
        } else {
            colors.text
        };
        let side = 16.0_f32.min(size.y - 8.0);
        paint(ui.painter(), Rect::from_center_size(rect.center(), Vec2::splat(side)), icon, color);
    }
    if tooltip.is_empty() { response } else { response.on_hover_text(tooltip) }
}

/// A text button in the toolbar's borderless style.
pub fn text_button(ui: &mut Ui, text: &str, selected: bool, tooltip: &str) -> Response {
    let colors = theme::colors();
    let font = FontId::proportional(13.0);
    let color = if selected { colors.accent } else { colors.text };
    let galley = ui.painter().layout_no_wrap(text.to_owned(), font, color);
    let size = vec2(galley.size().x + 20.0, 26.0);
    let (rect, response) = ui.allocate_exact_size(size, Sense::click());
    if ui.is_rect_visible(rect) {
        let fill = if selected {
            colors.accent.gamma_multiply(if colors.dark { 0.22 } else { 0.14 })
        } else if response.is_pointer_button_down_on() {
            colors.pressed
        } else if response.hovered() {
            colors.hover
        } else {
            Color32::TRANSPARENT
        };
        ui.painter().rect_filled(rect, CornerRadius::same(6), fill);
        ui.painter().galley(pos2(rect.center().x - galley.size().x / 2.0, rect.center().y - galley.size().y / 2.0), galley, color);
    }
    if tooltip.is_empty() { response } else { response.on_hover_text(tooltip) }
}

/// A 1-point vertical rule between toolbar groups.
pub fn divider(ui: &mut Ui) {
    let (rect, _) = ui.allocate_exact_size(vec2(9.0, 18.0), Sense::hover());
    ui.painter().line_segment([rect.center_top(), rect.center_bottom()], Stroke::new(1.0, theme::colors().hairline));
}
