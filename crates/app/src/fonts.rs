//! SF Pro and SF Mono for the interface, plus system fallbacks so symbols and
//! non-Latin text (outline titles, annotation labels, form values) render
//! instead of tofu boxes. egui's bundled fonts stay as the last resort.

use std::sync::Arc;

const PRIMARY: [(&str, egui::FontFamily); 2] = [
    ("/System/Library/Fonts/SFNS.ttf", egui::FontFamily::Proportional),
    ("/System/Library/Fonts/SFNSMono.ttf", egui::FontFamily::Monospace),
];

const FALLBACKS: [&str; 2] = [
    "/System/Library/Fonts/Apple Symbols.ttf",
    "/System/Library/Fonts/Supplemental/Arial Unicode.ttf",
];

fn load(fonts: &mut egui::FontDefinitions, path: &str) -> Option<String> {
    let data = std::fs::read(path).ok()?;
    let name = path.rsplit('/').next().unwrap_or(path).to_owned();
    fonts.font_data.insert(name.clone(), Arc::new(egui::FontData::from_owned(data)));
    Some(name)
}

pub fn install(ctx: &egui::Context) {
    let mut fonts = egui::FontDefinitions::default();
    for (path, family) in PRIMARY {
        if let Some(name) = load(&mut fonts, path) {
            fonts.families.entry(family).or_default().insert(0, name);
        }
    }
    for path in FALLBACKS {
        let Some(name) = load(&mut fonts, path) else { continue };
        for family in [egui::FontFamily::Proportional, egui::FontFamily::Monospace] {
            fonts.families.entry(family).or_default().push(name.clone());
        }
    }
    ctx.set_fonts(fonts);
}
