//! Per-document reader state: selection, layout, theme and page labels.

use std::collections::BTreeSet;

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum DisplayMode {
    SinglePage,
    TwoPage,
    Continuous,
}

impl DisplayMode {
    pub const ALL: [Self; 3] = [Self::SinglePage, Self::TwoPage, Self::Continuous];

    pub fn title(self) -> &'static str {
        match self {
            Self::SinglePage => "Single Page",
            Self::TwoPage => "Two Page",
            Self::Continuous => "Continuous",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum ReaderTheme {
    Day,
    Night,
    Sepia,
}

impl ReaderTheme {
    pub const ALL: [Self; 3] = [Self::Day, Self::Night, Self::Sepia];

    pub fn title(self) -> &'static str {
        match self {
            Self::Day => "Day",
            Self::Night => "Night",
            Self::Sepia => "Sepia",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum SidebarTab {
    Thumbnails,
    Contents,
    Bookmarks,
    Annotations,
}

impl SidebarTab {
    pub const ALL: [Self; 4] = [Self::Thumbnails, Self::Contents, Self::Bookmarks, Self::Annotations];

    pub fn title(self) -> &'static str {
        match self {
            Self::Thumbnails => "Thumbnails",
            Self::Contents => "Contents",
            Self::Bookmarks => "Bookmarks",
            Self::Annotations => "Annotations",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum PageLabelStyle {
    Document,
    Decimal,
    RomanUpper,
    RomanLower,
    Letters,
}

impl PageLabelStyle {
    pub const ALL: [Self; 5] = [
        Self::Document,
        Self::Decimal,
        Self::RomanUpper,
        Self::RomanLower,
        Self::Letters,
    ];

    pub fn title(self) -> &'static str {
        match self {
            Self::Document => "Document Labels",
            Self::Decimal => "Decimal",
            Self::RomanUpper => "Roman (I, II, III)",
            Self::RomanLower => "Roman (i, ii, iii)",
            Self::Letters => "Letters (A, B, C)",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Zoom {
    /// Fit the widest page to the viewport width; refits on resize.
    FitWidth,
    Scale(f32),
}

pub const MIN_ZOOM: f32 = 0.1;
pub const MAX_ZOOM: f32 = 8.0;
const ZOOM_STEP: f32 = 1.25;

#[derive(Debug, Clone)]
pub struct ReaderState {
    page_count: usize,
    selected_page_index: usize,
    selected_page_indexes: BTreeSet<usize>,
    pub display_mode: DisplayMode,
    pub theme: ReaderTheme,
    pub is_sidebar_visible: bool,
    pub sidebar_tab: SidebarTab,
    pub page_label_style: PageLabelStyle,
    pub page_label_start: i64,
    pub page_label_prefix: String,
    pub zoom: Zoom,
    /// The scale actually used for the last frame, so step zooms start from it.
    pub effective_scale: f32,
}

impl ReaderState {
    pub fn new(page_count: usize) -> Self {
        Self {
            page_count,
            selected_page_index: 0,
            selected_page_indexes: if page_count > 0 { BTreeSet::from([0]) } else { BTreeSet::new() },
            display_mode: DisplayMode::Continuous,
            theme: ReaderTheme::Night,
            is_sidebar_visible: true,
            sidebar_tab: SidebarTab::Thumbnails,
            page_label_style: PageLabelStyle::Document,
            page_label_start: 1,
            page_label_prefix: String::new(),
            zoom: Zoom::FitWidth,
            effective_scale: 1.0,
        }
    }

    pub fn page_count(&self) -> usize {
        self.page_count
    }

    pub fn selected_page_index(&self) -> usize {
        self.selected_page_index
    }

    pub fn selected_page_indexes(&self) -> &BTreeSet<usize> {
        &self.selected_page_indexes
    }

    pub fn selected_pages_vec(&self) -> Vec<usize> {
        self.selected_page_indexes.iter().copied().collect()
    }

    pub fn go_to_page_number(&mut self, number: usize) -> bool {
        number >= 1 && self.select_page(number - 1)
    }

    pub fn select_page(&mut self, index: usize) -> bool {
        if index >= self.page_count {
            return false;
        }
        self.selected_page_index = index;
        self.selected_page_indexes = BTreeSet::from([index]);
        true
    }

    /// Tracks the page under the viewport without disturbing a multi-selection.
    pub fn set_current_page(&mut self, index: usize) {
        if index < self.page_count {
            self.selected_page_index = index;
            if self.selected_page_indexes.len() <= 1 {
                self.selected_page_indexes = BTreeSet::from([index]);
            }
        }
    }

    pub fn select_pages(&mut self, indexes: BTreeSet<usize>, preferred: Option<usize>) -> bool {
        if indexes.iter().any(|index| *index >= self.page_count) {
            return false;
        }
        if !indexes.is_empty() {
            if let Some(preferred) = preferred.filter(|preferred| indexes.contains(preferred)) {
                self.selected_page_index = preferred;
            } else if !indexes.contains(&self.selected_page_index) {
                self.selected_page_index = *indexes.first().unwrap();
            }
        }
        self.selected_page_indexes = indexes;
        true
    }

    /// Clamps selection after the page count changes (delete, insert, undo).
    pub fn synchronize(&mut self, page_count: usize, preferred: Option<usize>) {
        self.page_count = page_count;
        if page_count == 0 {
            self.selected_page_index = 0;
            self.selected_page_indexes.clear();
            return;
        }
        let desired = preferred.unwrap_or(self.selected_page_index);
        let mut index = desired.min(page_count - 1);
        let valid: BTreeSet<usize> = self
            .selected_page_indexes
            .iter()
            .copied()
            .filter(|candidate| *candidate < page_count)
            .collect();
        let indexes = if valid.is_empty() { BTreeSet::from([index]) } else { valid };
        if !indexes.contains(&index) {
            index = *indexes.first().unwrap();
        }
        self.selected_page_index = index;
        self.selected_page_indexes = indexes;
    }

    pub fn zoom_in(&mut self) {
        self.zoom = Zoom::Scale((self.effective_scale * ZOOM_STEP).clamp(MIN_ZOOM, MAX_ZOOM));
    }

    pub fn zoom_out(&mut self) {
        self.zoom = Zoom::Scale((self.effective_scale / ZOOM_STEP).clamp(MIN_ZOOM, MAX_ZOOM));
    }

    pub fn actual_size(&mut self) {
        self.zoom = Zoom::Scale(1.0);
    }

    pub fn zoom_to_fit(&mut self) {
        self.zoom = Zoom::FitWidth;
    }

    /// Display label for a page. `document_label` is the PDF's own /PageLabels entry.
    pub fn page_label(&self, index: usize, document_label: Option<&str>) -> String {
        if index >= self.page_count {
            return String::new();
        }
        if self.page_label_style == PageLabelStyle::Document {
            return document_label
                .filter(|label| !label.is_empty())
                .map(str::to_owned)
                .unwrap_or_else(|| (index + 1).to_string());
        }
        let value = (self.page_label_start + index as i64).max(1);
        let body = match self.page_label_style {
            PageLabelStyle::Document | PageLabelStyle::Decimal => value.to_string(),
            PageLabelStyle::RomanUpper => roman(value),
            PageLabelStyle::RomanLower => roman(value).to_lowercase(),
            PageLabelStyle::Letters => letters(value),
        };
        let prefix: String = self.page_label_prefix.chars().take(20).collect();
        prefix + &body
    }
}

fn roman(value: i64) -> String {
    if value > 3999 {
        return value.to_string();
    }
    const SYMBOLS: [(i64, &str); 13] = [
        (1000, "M"), (900, "CM"), (500, "D"), (400, "CD"), (100, "C"), (90, "XC"),
        (50, "L"), (40, "XL"), (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I"),
    ];
    let mut remaining = value;
    let mut result = String::new();
    for (number, symbol) in SYMBOLS {
        while remaining >= number {
            result.push_str(symbol);
            remaining -= number;
        }
    }
    result
}

fn letters(value: i64) -> String {
    let mut remaining = value;
    let mut result = Vec::new();
    while remaining > 0 {
        remaining -= 1;
        result.push(b'A' + (remaining % 26) as u8);
        remaining /= 26;
    }
    result.reverse();
    String::from_utf8(result).unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn selection_navigation_and_synchronization() {
        let mut state = ReaderState::new(5);
        assert!(state.go_to_page_number(3));
        assert_eq!(state.selected_page_index(), 2);
        assert!(!state.go_to_page_number(0));
        assert!(!state.select_page(5));

        assert!(state.select_pages(BTreeSet::from([1, 3, 4]), Some(3)));
        assert_eq!(state.selected_page_index(), 3);
        assert!(!state.select_pages(BTreeSet::from([9]), None));

        state.synchronize(3, None);
        assert_eq!(state.selected_page_indexes(), &BTreeSet::from([1]));
        assert_eq!(state.selected_page_index(), 1);
        state.synchronize(0, None);
        assert!(state.selected_page_indexes().is_empty());
    }

    #[test]
    fn page_labels_follow_style_start_and_prefix() {
        let mut state = ReaderState::new(30);
        assert_eq!(state.page_label(0, Some("Cover")), "Cover");
        assert_eq!(state.page_label(1, None), "2");
        state.page_label_style = PageLabelStyle::RomanLower;
        assert_eq!(state.page_label(3, None), "iv");
        state.page_label_style = PageLabelStyle::RomanUpper;
        state.page_label_start = 1990;
        assert_eq!(state.page_label(4, None), "MCMXCIV");
        state.page_label_style = PageLabelStyle::Letters;
        state.page_label_start = 1;
        state.page_label_prefix = "A-".into();
        assert_eq!(state.page_label(26, None), "A-AA");
        assert_eq!(state.page_label(99, None), "");
    }

    #[test]
    fn zoom_steps_start_from_effective_scale_and_clamp() {
        let mut state = ReaderState::new(1);
        state.effective_scale = 0.8;
        state.zoom_in();
        assert_eq!(state.zoom, Zoom::Scale(1.0));
        state.effective_scale = MAX_ZOOM;
        state.zoom_in();
        assert_eq!(state.zoom, Zoom::Scale(MAX_ZOOM));
        state.zoom_to_fit();
        assert_eq!(state.zoom, Zoom::FitWidth);
    }
}
