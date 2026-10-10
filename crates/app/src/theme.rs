//! Chrome and reader workspace colors. The window chrome follows the reader
//! theme so the toolbar, sidebar and desk read as one surface; teal ink is
//! the single accent (yellow, orange and red already mean highlights, search
//! hits and redaction on the page).

use std::sync::atomic::{AtomicU8, Ordering};

use egui::{Color32, CornerRadius, FontFamily, FontId, Margin, Shadow, Stroke, TextStyle, Vec2};

use crate::reader_state::ReaderTheme;

pub struct Palette {
    /// Toolbar and title bar.
    pub chrome: Color32,
    /// Sidebar and inspector panels.
    pub sidebar: Color32,
    /// The surface pages sit on.
    pub desk: Color32,
    /// Dialogs, popups and the floating page controls.
    pub raised: Color32,
    /// Text fields and other wells.
    pub well: Color32,
    pub control: Color32,
    pub hover: Color32,
    pub pressed: Color32,
    pub hairline: Color32,
    pub text: Color32,
    pub muted: Color32,
    pub faint: Color32,
    pub accent: Color32,
    pub on_accent: Color32,
    pub danger: Color32,
    pub warning: Color32,
    pub dark: bool,
}

const NIGHT: Palette = Palette {
    chrome: Color32::from_rgb(38, 40, 44),
    sidebar: Color32::from_rgb(33, 35, 38),
    desk: Color32::from_rgb(24, 25, 28),
    raised: Color32::from_rgb(46, 48, 53),
    well: Color32::from_rgb(28, 30, 33),
    control: Color32::from_rgb(52, 55, 60),
    hover: Color32::from_rgb(60, 63, 69),
    pressed: Color32::from_rgb(70, 74, 80),
    hairline: Color32::from_rgb(54, 57, 63),
    text: Color32::from_rgb(232, 230, 225),
    muted: Color32::from_rgb(158, 160, 166),
    faint: Color32::from_rgb(108, 111, 118),
    accent: Color32::from_rgb(86, 194, 180),
    on_accent: Color32::from_rgb(12, 34, 31),
    danger: Color32::from_rgb(240, 113, 103),
    warning: Color32::from_rgb(232, 184, 92),
    dark: true,
};

const DAY: Palette = Palette {
    chrome: Color32::from_rgb(242, 243, 245),
    sidebar: Color32::from_rgb(234, 236, 239),
    desk: Color32::from_rgb(214, 217, 222),
    raised: Color32::from_rgb(250, 250, 251),
    well: Color32::from_rgb(255, 255, 255),
    control: Color32::from_rgb(226, 228, 232),
    hover: Color32::from_rgb(216, 219, 224),
    pressed: Color32::from_rgb(204, 208, 214),
    hairline: Color32::from_rgb(208, 211, 217),
    text: Color32::from_rgb(30, 32, 36),
    muted: Color32::from_rgb(98, 103, 112),
    faint: Color32::from_rgb(150, 154, 162),
    accent: Color32::from_rgb(22, 122, 110),
    on_accent: Color32::WHITE,
    danger: Color32::from_rgb(196, 52, 44),
    warning: Color32::from_rgb(166, 110, 0),
    dark: false,
};

const SEPIA: Palette = Palette {
    chrome: Color32::from_rgb(233, 224, 205),
    sidebar: Color32::from_rgb(226, 215, 193),
    desk: Color32::from_rgb(190, 174, 142),
    raised: Color32::from_rgb(242, 235, 220),
    well: Color32::from_rgb(249, 244, 233),
    control: Color32::from_rgb(218, 206, 182),
    hover: Color32::from_rgb(208, 195, 168),
    pressed: Color32::from_rgb(196, 182, 153),
    hairline: Color32::from_rgb(202, 188, 160),
    text: Color32::from_rgb(56, 44, 30),
    muted: Color32::from_rgb(112, 96, 74),
    faint: Color32::from_rgb(156, 140, 114),
    accent: Color32::from_rgb(34, 110, 100),
    on_accent: Color32::WHITE,
    danger: Color32::from_rgb(178, 52, 40),
    warning: Color32::from_rgb(150, 98, 10),
    dark: false,
};

static CURRENT: AtomicU8 = AtomicU8::new(u8::MAX);

fn palette_for(theme: ReaderTheme) -> &'static Palette {
    match theme {
        ReaderTheme::Day => &DAY,
        ReaderTheme::Night => &NIGHT,
        ReaderTheme::Sepia => &SEPIA,
    }
}

fn theme_code(theme: ReaderTheme) -> u8 {
    match theme {
        ReaderTheme::Day => 0,
        ReaderTheme::Night => 1,
        ReaderTheme::Sepia => 2,
    }
}

/// The palette of the theme last passed to [`apply`].
pub fn colors() -> &'static Palette {
    match CURRENT.load(Ordering::Relaxed) {
        0 => &DAY,
        2 => &SEPIA,
        _ => &NIGHT,
    }
}

pub fn workspace_color(theme: ReaderTheme) -> Color32 {
    palette_for(theme).desk
}

pub fn page_shadow() -> Color32 {
    if colors().dark { Color32::from_black_alpha(140) } else { Color32::from_black_alpha(46) }
}

/// Restyles egui for `theme`; cheap to call every frame.
pub fn apply(ctx: &egui::Context, theme: ReaderTheme) {
    let code = theme_code(theme);
    if CURRENT.swap(code, Ordering::Relaxed) == code {
        return;
    }
    let p = palette_for(theme);
    let mut visuals = if p.dark { egui::Visuals::dark() } else { egui::Visuals::light() };
    visuals.panel_fill = p.sidebar;
    visuals.window_fill = p.raised;
    visuals.window_stroke = Stroke::new(1.0, p.hairline);
    visuals.window_corner_radius = CornerRadius::same(12);
    visuals.menu_corner_radius = CornerRadius::same(8);
    visuals.window_shadow = Shadow { offset: [0, 10], blur: 32, spread: 0, color: Color32::from_black_alpha(if p.dark { 110 } else { 40 }) };
    visuals.popup_shadow = Shadow { offset: [0, 4], blur: 14, spread: 0, color: Color32::from_black_alpha(if p.dark { 90 } else { 30 }) };
    visuals.extreme_bg_color = p.well;
    visuals.text_edit_bg_color = Some(p.well);
    visuals.faint_bg_color = p.control;
    visuals.code_bg_color = p.control;
    visuals.override_text_color = None;
    visuals.weak_text_color = Some(p.muted);
    visuals.hyperlink_color = p.accent;
    visuals.warn_fg_color = p.warning;
    visuals.error_fg_color = p.danger;
    visuals.selection.bg_fill = p.accent.gamma_multiply(if p.dark { 0.3 } else { 0.2 });
    visuals.selection.stroke = Stroke::new(1.0, p.accent);
    visuals.striped = false;
    visuals.indent_has_left_vline = false;

    let radius = CornerRadius::same(4);
    let w = &mut visuals.widgets;
    w.noninteractive.bg_fill = p.raised;
    w.noninteractive.weak_bg_fill = p.raised;
    w.noninteractive.bg_stroke = Stroke::new(1.0, p.hairline);
    w.noninteractive.fg_stroke = Stroke::new(1.0, p.text);
    w.noninteractive.corner_radius = radius;
    for (state, fill) in [(&mut w.inactive, p.control), (&mut w.hovered, p.hover), (&mut w.active, p.pressed), (&mut w.open, p.hover)] {
        state.bg_fill = fill;
        state.weak_bg_fill = fill;
        state.bg_stroke = Stroke::NONE;
        state.corner_radius = radius;
        state.expansion = 0.0;
    }
    w.inactive.fg_stroke = Stroke::new(1.0, p.text);
    w.hovered.fg_stroke = Stroke::new(1.5, p.text);
    w.active.fg_stroke = Stroke::new(1.5, p.text);
    w.open.fg_stroke = Stroke::new(1.0, p.text);
    let egui_theme = if p.dark { egui::Theme::Dark } else { egui::Theme::Light };
    ctx.set_theme(egui_theme);
    ctx.set_visuals_of(egui_theme, visuals);

    ctx.all_styles_mut(|style| {
        style.text_styles = [
            (TextStyle::Small, FontId::new(11.0, FontFamily::Proportional)),
            (TextStyle::Body, FontId::new(13.0, FontFamily::Proportional)),
            (TextStyle::Button, FontId::new(13.0, FontFamily::Proportional)),
            (TextStyle::Heading, FontId::new(17.0, FontFamily::Proportional)),
            (TextStyle::Monospace, FontId::new(12.0, FontFamily::Monospace)),
        ]
        .into();
        let spacing = &mut style.spacing;
        spacing.item_spacing = Vec2::new(8.0, 6.0);
        spacing.button_padding = Vec2::new(10.0, 4.0);
        spacing.interact_size.y = 24.0;
        spacing.window_margin = Margin::same(18);
        spacing.menu_margin = Margin::same(6);
        spacing.combo_height = 280.0;
        spacing.indent = 16.0;
    });
}

/// The button for a dialog's main action.
pub fn primary(text: &str) -> egui::Button<'static> {
    let colors = colors();
    egui::Button::new(egui::RichText::new(text).color(colors.on_accent)).fill(colors.accent)
}

/// The button for an action that destroys content or discards work.
pub fn destructive(text: &str) -> egui::Button<'static> {
    egui::Button::new(egui::RichText::new(text).color(Color32::WHITE)).fill(colors().danger)
}
