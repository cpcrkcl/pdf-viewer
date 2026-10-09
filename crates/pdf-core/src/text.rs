//! Page text, search, selection and links, extracted with PDFium.

use std::sync::atomic::{AtomicBool, Ordering};

use pdfium_render::prelude::*;

use crate::engine;
use crate::error::{CoreError, CoreResult};
use crate::geometry::{PageGeometry, PdfBox};

/// Characters of one page with their user-space boxes. Characters PDFium
/// synthesizes (spaces, line breaks) have no box.
#[derive(Debug, Clone, Default)]
pub struct PageText {
    pub chars: Vec<char>,
    pub boxes: Vec<Option<PdfBox>>,
}

impl PageText {
    pub fn string(&self) -> String {
        self.chars.iter().collect()
    }

    pub fn has_text(&self) -> bool {
        self.chars.iter().any(|c| !c.is_whitespace())
    }

    /// The index of the character nearest `point` (user space).
    pub fn char_at(&self, point: (f32, f32)) -> Option<usize> {
        let mut best: Option<(usize, f32)> = None;
        for (index, rect) in self.boxes.iter().enumerate() {
            let Some(rect) = rect else { continue };
            let distance = rect.distance_to(point);
            if best.is_none_or(|(_, current)| distance < current) {
                best = Some((index, distance));
            }
        }
        best.filter(|(_, distance)| *distance < 24.0).map(|(index, _)| index)
    }

    /// One box per line covering chars `start..end`.
    pub fn line_boxes(&self, start: usize, end: usize) -> Vec<PdfBox> {
        let mut lines: Vec<PdfBox> = Vec::new();
        for rect in self.boxes[start.min(self.boxes.len())..end.min(self.boxes.len())].iter().flatten() {
            match lines.last_mut() {
                Some(line) if same_line(line, rect) => *line = line.union(rect),
                _ => lines.push(*rect),
            }
        }
        lines
    }

    pub fn substring(&self, start: usize, end: usize) -> String {
        self.chars[start.min(self.chars.len())..end.min(self.chars.len())].iter().collect()
    }
}

fn same_line(a: &PdfBox, b: &PdfBox) -> bool {
    let overlap = a.y1.min(b.y1) - a.y0.max(b.y0);
    overlap > 0.5 * a.height().min(b.height())
}

#[derive(Debug, Clone)]
pub enum LinkTarget {
    Page(usize),
    Uri(String),
}

#[derive(Debug, Clone)]
pub struct PageLink {
    pub rect: PdfBox,
    pub target: LinkTarget,
}

/// Per-page facts the reader needs: geometry, label, links.
#[derive(Debug, Clone)]
pub struct PageInfo {
    pub geometry: PageGeometry,
    pub label: Option<String>,
    pub links: Vec<PageLink>,
}

pub fn page_infos(bytes: &[u8]) -> CoreResult<Vec<PageInfo>> {
    let document = engine::load(bytes.to_vec(), None)?;
    let structure = crate::structure::parse(bytes).ok();
    let page_ids = structure.as_ref().map(crate::structure::page_ids).unwrap_or_default();
    document
        .pages()
        .iter()
        .enumerate()
        .map(|(index, page)| {
            let visible = page
                .boundaries()
                .crop()
                .or_else(|_| page.boundaries().media())
                .map(|boundary| to_box(&boundary.bounds))
                .unwrap_or_else(|_| PdfBox::new(0.0, 0.0, page.width().value, page.height().value));
            let rotation = match (structure.as_ref(), page_ids.get(index)) {
                (Some(document), Some(id)) => crate::structure::rotation(document, *id),
                _ => rotation_degrees(page.rotation().unwrap_or(PdfPageRenderRotation::None)),
            };
            let links = page
                .links()
                .iter()
                .filter_map(|link| {
                    let rect = to_box(&link.rect().ok()?);
                    let target = if let Some(destination) = link.destination() {
                        LinkTarget::Page(destination.page_index().ok()? as usize)
                    } else {
                        let action = link.action()?;
                        if let Some(uri) = action.as_uri_action() {
                            LinkTarget::Uri(uri.uri().ok()?)
                        } else {
                            let destination = action.as_local_destination_action()?.destination().ok()?;
                            LinkTarget::Page(destination.page_index().ok()? as usize)
                        }
                    };
                    Some(PageLink { rect, target })
                })
                .collect();
            Ok(PageInfo {
                geometry: PageGeometry { visible, rotation },
                label: page.label().map(str::to_owned),
                links,
            })
        })
        .collect()
}

fn rotation_degrees(rotation: PdfPageRenderRotation) -> i64 {
    match rotation {
        PdfPageRenderRotation::None => 0,
        PdfPageRenderRotation::Degrees90 => 90,
        PdfPageRenderRotation::Degrees180 => 180,
        PdfPageRenderRotation::Degrees270 => 270,
    }
}

pub fn to_box(rect: &PdfRect) -> PdfBox {
    PdfBox::new(rect.left().value, rect.bottom().value, rect.right().value, rect.top().value)
}

/// Extracts every page's characters. Returns `Cancelled` if `cancel` is set.
pub fn build_text_index(bytes: &[u8], cancel: &AtomicBool) -> CoreResult<Vec<PageText>> {
    let document = engine::load(bytes.to_vec(), None)?;
    let mut pages = Vec::with_capacity(document.pages().len() as usize);
    for page in document.pages().iter() {
        if cancel.load(Ordering::Relaxed) {
            return Err(CoreError::Cancelled);
        }
        let mut text = PageText::default();
        if let Ok(page_text) = page.text() {
            for character in page_text.chars().iter() {
                let Some(value) = character.unicode_char() else { continue };
                let generated = character.is_generated().unwrap_or(false);
                let rect = if generated || value.is_whitespace() {
                    None
                } else {
                    character.loose_bounds().ok().map(|rect| to_box(&rect))
                };
                text.chars.push(if value == '\r' { '\n' } else { value });
                text.boxes.push(rect);
            }
        }
        pages.push(text);
    }
    Ok(pages)
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct SearchOptions {
    pub case_sensitive: bool,
    pub whole_words: bool,
}

#[derive(Debug, Clone, PartialEq)]
pub struct SearchMatch {
    pub page: usize,
    pub start: usize,
    pub end: usize,
    pub text: String,
    /// One box per line of the match, user space.
    pub boxes: Vec<PdfBox>,
}

impl SearchMatch {
    pub fn bounds(&self) -> Option<PdfBox> {
        self.boxes.iter().copied().reduce(|a, b| a.union(&b))
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum SearchOutcome {
    Matches(Vec<SearchMatch>),
    NoMatches,
    TextUnavailable,
}

pub fn search(pages: &[PageText], query: &str, options: SearchOptions, cancel: &AtomicBool) -> CoreResult<SearchOutcome> {
    let needle: Vec<char> = fold(query.trim(), options.case_sensitive);
    if needle.is_empty() {
        return Ok(SearchOutcome::NoMatches);
    }
    if !pages.iter().any(PageText::has_text) {
        return Ok(SearchOutcome::TextUnavailable);
    }
    let mut matches = Vec::new();
    for (page_index, page) in pages.iter().enumerate() {
        if cancel.load(Ordering::Relaxed) {
            return Err(CoreError::Cancelled);
        }
        let haystack: Vec<char> = page.chars.iter().map(|c| fold_char(*c, options.case_sensitive)).collect();
        let mut start = 0;
        while start + needle.len() <= haystack.len() {
            if haystack[start..start + needle.len()] == needle[..] {
                let end = start + needle.len();
                let bounded = !options.whole_words
                    || (!start.checked_sub(1).is_some_and(|before| is_word(page.chars[before]))
                        && !page.chars.get(end).is_some_and(|after| is_word(*after)));
                if bounded {
                    let boxes = page.line_boxes(start, end);
                    if !boxes.is_empty() {
                        matches.push(SearchMatch {
                            page: page_index,
                            start,
                            end,
                            text: page.substring(start, end),
                            boxes,
                        });
                    }
                    start = end;
                    continue;
                }
            }
            start += 1;
        }
    }
    Ok(if matches.is_empty() {
        SearchOutcome::NoMatches
    } else {
        SearchOutcome::Matches(matches)
    })
}

fn is_word(c: char) -> bool {
    c.is_alphanumeric() || c == '_'
}

fn fold(text: &str, case_sensitive: bool) -> Vec<char> {
    text.chars().map(|c| fold_char(c, case_sensitive)).collect()
}

/// Case folding plus diacritic folding for Latin letters, character for
/// character so match offsets stay aligned with page text.
fn fold_char(c: char, case_sensitive: bool) -> char {
    let c = if case_sensitive { c } else { c.to_lowercase().next().unwrap_or(c) };
    let base = match c {
        'à' | 'á' | 'â' | 'ã' | 'ä' | 'å' | 'ā' => 'a',
        'À' | 'Á' | 'Â' | 'Ã' | 'Ä' | 'Å' | 'Ā' => 'A',
        'ç' | 'ć' | 'č' => 'c',
        'Ç' | 'Ć' | 'Č' => 'C',
        'è' | 'é' | 'ê' | 'ë' | 'ē' | 'ę' | 'ě' => 'e',
        'È' | 'É' | 'Ê' | 'Ë' | 'Ē' | 'Ę' | 'Ě' => 'E',
        'ì' | 'í' | 'î' | 'ï' | 'ī' => 'i',
        'Ì' | 'Í' | 'Î' | 'Ï' | 'Ī' => 'I',
        'ñ' | 'ń' | 'ň' => 'n',
        'Ñ' | 'Ń' | 'Ň' => 'N',
        'ò' | 'ó' | 'ô' | 'õ' | 'ö' | 'ø' | 'ō' => 'o',
        'Ò' | 'Ó' | 'Ô' | 'Õ' | 'Ö' | 'Ø' | 'Ō' => 'O',
        'ù' | 'ú' | 'û' | 'ü' | 'ū' | 'ů' => 'u',
        'Ù' | 'Ú' | 'Û' | 'Ü' | 'Ū' | 'Ů' => 'U',
        'ý' | 'ÿ' => 'y',
        'Ý' | 'Ÿ' => 'Y',
        'š' | 'ś' => 's',
        'Š' | 'Ś' => 'S',
        'ž' | 'ź' | 'ż' => 'z',
        'Ž' | 'Ź' | 'Ż' => 'Z',
        // Ligatures and typographic punctuation PDFs commonly carry.
        '\u{2019}' | '\u{2018}' => '\'',
        '\u{201C}' | '\u{201D}' => '"',
        '\u{00A0}' => ' ',
        other => other,
    };
    base
}
