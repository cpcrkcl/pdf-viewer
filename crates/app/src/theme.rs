//! Catppuccin Mocha chrome plus the reader workspace colors.

use egui::Color32;

use crate::reader_state::ReaderTheme;

pub mod mocha {
    use egui::Color32;
    pub const BASE: Color32 = Color32::from_rgb(30, 30, 46);
    pub const MANTLE: Color32 = Color32::from_rgb(24, 24, 37);
    pub const CRUST: Color32 = Color32::from_rgb(17, 17, 27);
    pub const SURFACE0: Color32 = Color32::from_rgb(49, 50, 68);
    pub const SURFACE1: Color32 = Color32::from_rgb(69, 71, 90);
    pub const SURFACE2: Color32 = Color32::from_rgb(88, 91, 112);
    pub const OVERLAY0: Color32 = Color32::from_rgb(108, 112, 134);
    pub const SUBTEXT0: Color32 = Color32::from_rgb(166, 173, 200);
    pub const TEXT: Color32 = Color32::from_rgb(205, 214, 244);
    pub const BLUE: Color32 = Color32::from_rgb(137, 180, 250);
    pub const LAVENDER: Color32 = Color32::from_rgb(180, 190, 254);
    pub const RED: Color32 = Color32::from_rgb(243, 139, 168);
    pub const PEACH: Color32 = Color32::from_rgb(250, 179, 135);
    pub const YELLOW: Color32 = Color32::from_rgb(249, 226, 175);
    pub const GREEN: Color32 = Color32::from_rgb(166, 227, 161);
}

pub fn workspace_color(theme: ReaderTheme) -> Color32 {
    match theme {
        ReaderTheme::Day => Color32::from_gray(209),
        ReaderTheme::Night => mocha::BASE,
        ReaderTheme::Sepia => Color32::from_rgb(179, 161, 125),
    }
}

pub fn thumbnail_background(theme: ReaderTheme) -> Color32 {
    match theme {
        ReaderTheme::Day => Color32::from_gray(235),
        ReaderTheme::Night => mocha::MANTLE,
        ReaderTheme::Sepia => Color32::from_rgb(219, 204, 173),
    }
}

pub fn apply(ctx: &egui::Context) {
    let mut visuals = egui::Visuals::dark();
    visuals.panel_fill = mocha::MANTLE;
    visuals.window_fill = mocha::BASE;
    visuals.extreme_bg_color = mocha::CRUST;
    visuals.faint_bg_color = mocha::SURFACE0;
    visuals.override_text_color = Some(mocha::TEXT);
    visuals.hyperlink_color = mocha::BLUE;
    visuals.selection.bg_fill = mocha::BLUE.linear_multiply(0.45);
    visuals.selection.stroke.color = mocha::LAVENDER;
    visuals.widgets.noninteractive.bg_fill = mocha::BASE;
    visuals.widgets.inactive.bg_fill = mocha::SURFACE0;
    visuals.widgets.inactive.weak_bg_fill = mocha::SURFACE0;
    visuals.widgets.hovered.bg_fill = mocha::SURFACE1;
    visuals.widgets.hovered.weak_bg_fill = mocha::SURFACE1;
    visuals.widgets.active.bg_fill = mocha::SURFACE2;
    visuals.widgets.active.weak_bg_fill = mocha::SURFACE2;
    ctx.set_visuals(visuals);
}

pub const PAGE_SHADOW: Color32 = Color32::from_black_alpha(90);
pub const SELECTION: Color32 = mocha::BLUE;
