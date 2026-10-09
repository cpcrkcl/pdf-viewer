//! System font fallbacks so symbols and non-Latin text (outline titles,
//! annotation labels, form values) render instead of tofu boxes.

use std::sync::Arc;

const FALLBACKS: [&str; 2] = [
    "/System/Library/Fonts/Apple Symbols.ttf",
    "/System/Library/Fonts/Supplemental/Arial Unicode.ttf",
];

pub fn install(ctx: &egui::Context) {
    let mut fonts = egui::FontDefinitions::default();
    for path in FALLBACKS {
        let Ok(data) = std::fs::read(path) else { continue };
        let name = path.rsplit('/').next().unwrap_or(path).to_owned();
        fonts.font_data.insert(name.clone(), Arc::new(egui::FontData::from_owned(data)));
        for family in [egui::FontFamily::Proportional, egui::FontFamily::Monospace] {
            fonts.families.entry(family).or_default().push(name.clone());
        }
    }
    ctx.set_fonts(fonts);
}
