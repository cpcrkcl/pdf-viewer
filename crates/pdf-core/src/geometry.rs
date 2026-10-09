//! Rectangles in PDF user space and the mapping to displayed page space.

use serde::{Deserialize, Serialize};

/// An axis-aligned rectangle in PDF user space (y grows upward).
#[derive(Debug, Clone, Copy, PartialEq, Default, Serialize, Deserialize)]
pub struct PdfBox {
    pub x0: f32,
    pub y0: f32,
    pub x1: f32,
    pub y1: f32,
}

impl PdfBox {
    pub fn new(x0: f32, y0: f32, x1: f32, y1: f32) -> Self {
        Self {
            x0: x0.min(x1),
            y0: y0.min(y1),
            x1: x0.max(x1),
            y1: y0.max(y1),
        }
    }

    pub fn from_array(values: [f32; 4]) -> Self {
        Self::new(values[0], values[1], values[2], values[3])
    }

    pub fn to_array(self) -> [f32; 4] {
        [self.x0, self.y0, self.x1, self.y1]
    }

    pub fn from_points(a: (f32, f32), b: (f32, f32)) -> Self {
        Self::new(a.0, a.1, b.0, b.1)
    }

    pub fn width(&self) -> f32 {
        self.x1 - self.x0
    }

    pub fn height(&self) -> f32 {
        self.y1 - self.y0
    }

    pub fn center(&self) -> (f32, f32) {
        ((self.x0 + self.x1) / 2.0, (self.y0 + self.y1) / 2.0)
    }

    pub fn is_finite(&self) -> bool {
        [self.x0, self.y0, self.x1, self.y1].iter().all(|value| value.is_finite())
    }

    pub fn is_empty(&self) -> bool {
        self.width() <= 0.0 || self.height() <= 0.0
    }

    pub fn union(&self, other: &Self) -> Self {
        Self::new(
            self.x0.min(other.x0),
            self.y0.min(other.y0),
            self.x1.max(other.x1),
            self.y1.max(other.y1),
        )
    }

    pub fn intersects(&self, other: &Self) -> bool {
        self.x0 < other.x1 && other.x0 < self.x1 && self.y0 < other.y1 && other.y0 < self.y1
    }

    pub fn intersection(&self, other: &Self) -> Option<Self> {
        let result = Self {
            x0: self.x0.max(other.x0),
            y0: self.y0.max(other.y0),
            x1: self.x1.min(other.x1),
            y1: self.y1.min(other.y1),
        };
        (!result.is_empty()).then_some(result)
    }

    pub fn contains(&self, point: (f32, f32)) -> bool {
        point.0 >= self.x0 && point.0 <= self.x1 && point.1 >= self.y0 && point.1 <= self.y1
    }

    pub fn inset(&self, dx: f32, dy: f32) -> Self {
        Self::new(self.x0 + dx, self.y0 + dy, self.x1 - dx, self.y1 - dy)
    }

    pub fn offset(&self, dx: f32, dy: f32) -> Self {
        Self::new(self.x0 + dx, self.y0 + dy, self.x1 + dx, self.y1 + dy)
    }

    /// Moves (and if necessary shrinks) `self` to lie inside `bounds`.
    pub fn clamped_to(&self, bounds: &Self) -> Self {
        let width = self.width().max(1.0).min(bounds.width());
        let height = self.height().max(1.0).min(bounds.height());
        let x0 = self.x0.max(bounds.x0).min(bounds.x1 - width);
        let y0 = self.y0.max(bounds.y0).min(bounds.y1 - height);
        Self::new(x0, y0, x0 + width, y0 + height)
    }

    pub fn distance_to(&self, point: (f32, f32)) -> f32 {
        let dx = (self.x0 - point.0).max(0.0).max(point.0 - self.x1);
        let dy = (self.y0 - point.1).max(0.0).max(point.1 - self.y1);
        dx.hypot(dy)
    }
}

/// How a page's user space appears on screen: the visible box and the
/// clockwise `/Rotate`.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct PageGeometry {
    pub visible: PdfBox,
    pub rotation: i64,
}

impl PageGeometry {
    /// Displayed size in points (width and height swap for 90°/270°).
    pub fn display_size(&self) -> (f32, f32) {
        let (w, h) = (self.visible.width(), self.visible.height());
        if self.rotation % 180 == 0 { (w, h) } else { (h, w) }
    }

    /// User space → displayed space (origin top-left, y down, points).
    pub fn to_display(&self, point: (f32, f32)) -> (f32, f32) {
        let (w, h) = (self.visible.width(), self.visible.height());
        let u = point.0 - self.visible.x0;
        let v = point.1 - self.visible.y0;
        match self.rotation {
            90 => (v, u),
            180 => (w - u, v),
            270 => (h - v, w - u),
            _ => (u, h - v),
        }
    }

    /// Displayed space → user space.
    pub fn from_display(&self, point: (f32, f32)) -> (f32, f32) {
        let (w, h) = (self.visible.width(), self.visible.height());
        let (dx, dy) = point;
        let (u, v) = match self.rotation {
            90 => (dy, dx),
            180 => (w - dx, dy),
            270 => (w - dy, h - dx),
            _ => (dx, h - dy),
        };
        (u + self.visible.x0, v + self.visible.y0)
    }

    /// A user-space box as a displayed-space `(min, max)` rectangle.
    pub fn box_to_display(&self, rect: &PdfBox) -> ((f32, f32), (f32, f32)) {
        let a = self.to_display((rect.x0, rect.y0));
        let b = self.to_display((rect.x1, rect.y1));
        ((a.0.min(b.0), a.1.min(b.1)), (a.0.max(b.0), a.1.max(b.1)))
    }

    pub fn box_from_display(&self, min: (f32, f32), max: (f32, f32)) -> PdfBox {
        PdfBox::from_points(self.from_display(min), self.from_display(max))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn display_mapping_round_trips_for_every_rotation() {
        for rotation in [0, 90, 180, 270] {
            let geometry = PageGeometry {
                visible: PdfBox::new(10.0, 20.0, 210.0, 320.0),
                rotation,
            };
            for point in [(10.0, 20.0), (210.0, 320.0), (60.0, 100.0)] {
                let display = geometry.to_display(point);
                let back = geometry.from_display(display);
                assert!((back.0 - point.0).abs() < 1e-3 && (back.1 - point.1).abs() < 1e-3, "{rotation}: {point:?}");
                let (w, h) = geometry.display_size();
                assert!(display.0 >= -1e-3 && display.0 <= w + 1e-3 && display.1 >= -1e-3 && display.1 <= h + 1e-3);
            }
        }
        let upright = PageGeometry { visible: PdfBox::new(0.0, 0.0, 100.0, 200.0), rotation: 0 };
        assert_eq!(upright.to_display((0.0, 200.0)), (0.0, 0.0), "top-left is the display origin");
        let turned = PageGeometry { visible: PdfBox::new(0.0, 0.0, 100.0, 200.0), rotation: 90 };
        assert_eq!(turned.to_display((0.0, 200.0)), (200.0, 0.0), "top-left moves to top-right");
    }

    #[test]
    fn clamping_keeps_boxes_on_the_page() {
        let page = PdfBox::new(0.0, 0.0, 100.0, 100.0);
        let moved = PdfBox::new(90.0, -10.0, 130.0, 20.0).clamped_to(&page);
        assert_eq!(moved, PdfBox::new(60.0, 0.0, 100.0, 30.0));
        let huge = PdfBox::new(-50.0, -50.0, 500.0, 500.0).clamped_to(&page);
        assert_eq!(huge, page);
    }
}
