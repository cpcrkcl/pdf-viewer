//! Background page rendering.
//!
//! A single worker thread owns the PDFium documents it renders from (PDFium
//! serializes calls anyway). The UI queues requests every frame for the pages
//! it needs; the newest requests are served first and stale generations are
//! dropped, so scrolling and zooming stay responsive on large documents.

use std::collections::{HashMap, HashSet, VecDeque};
use std::sync::mpsc::{Receiver, Sender, channel};
use std::sync::{Arc, Condvar, Mutex};

use egui::{ColorImage, TextureHandle, TextureOptions};
use pdfium_render::prelude::*;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct DocumentKey {
    pub tab: u64,
    pub generation: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct TextureKey {
    pub document: DocumentKey,
    pub page: usize,
    pub width_px: u32,
}

struct Request {
    key: TextureKey,
    bytes: Arc<Vec<u8>>,
}

#[derive(Default)]
struct Queue {
    requests: VecDeque<Request>,
    pending: HashSet<TextureKey>,
    live_documents: HashSet<DocumentKey>,
}

pub struct RenderService {
    queue: Arc<(Mutex<Queue>, Condvar)>,
    results: Receiver<(TextureKey, Option<ColorImage>)>,
    textures: HashMap<TextureKey, (TextureHandle, u64)>,
    failed: HashSet<TextureKey>,
    frame: u64,
}

const TEXTURE_BUDGET: usize = 160;
const QUEUE_LIMIT: usize = 64;

impl RenderService {
    pub fn new(ctx: egui::Context) -> Self {
        let queue: Arc<(Mutex<Queue>, Condvar)> = Arc::default();
        let (sender, results) = channel();
        let worker_queue = Arc::clone(&queue);
        std::thread::Builder::new()
            .name("pdf-render".into())
            .spawn(move || worker(worker_queue, sender, ctx))
            .expect("render thread starts");
        Self {
            queue,
            results,
            textures: HashMap::new(),
            failed: HashSet::new(),
            frame: 0,
        }
    }

    /// Uploads finished renders and evicts least-recently-used textures.
    pub fn begin_frame(&mut self, ctx: &egui::Context) {
        self.frame += 1;
        while let Ok((key, image)) = self.results.try_recv() {
            match image {
                Some(image) => {
                    let name = format!("page-{}-{}-{}-{}", key.document.tab, key.document.generation, key.page, key.width_px);
                    let handle = ctx.load_texture(name, image, TextureOptions::LINEAR);
                    self.textures.insert(key, (handle, self.frame));
                }
                None => {
                    self.failed.insert(key);
                }
            }
        }
        if self.textures.len() > TEXTURE_BUDGET {
            let mut by_age: Vec<_> = self.textures.iter().map(|(key, (_, used))| (*used, *key)).collect();
            by_age.sort_unstable_by_key(|(used, _)| *used);
            for (_, key) in by_age.into_iter().take(self.textures.len() - TEXTURE_BUDGET) {
                self.textures.remove(&key);
            }
        }
    }

    /// Declares which documents are still open; others are released.
    pub fn retain_documents(&mut self, live: HashSet<DocumentKey>) {
        self.textures.retain(|key, _| live.contains(&key.document) || live.iter().any(|doc| doc.tab == key.document.tab));
        let (lock, _) = &*self.queue;
        lock.lock().unwrap().live_documents = live;
    }

    /// The exact texture if ready, otherwise the closest-width texture for the
    /// same page (possibly from the previous revision) as a placeholder.
    /// Queues a render when the exact texture is missing.
    pub fn texture(&mut self, key: TextureKey, bytes: &Arc<Vec<u8>>) -> Option<TextureHandle> {
        if let Some((handle, used)) = self.textures.get_mut(&key) {
            *used = self.frame;
            return Some(handle.clone());
        }
        if !self.failed.contains(&key) {
            self.request(key, bytes);
        }
        self.textures
            .iter()
            .filter(|(candidate, _)| {
                candidate.document.tab == key.document.tab && candidate.page == key.page && candidate.document.generation == key.document.generation
            })
            .min_by_key(|(candidate, _)| candidate.width_px.abs_diff(key.width_px))
            .map(|(_, (handle, _))| handle.clone())
    }

    fn request(&self, key: TextureKey, bytes: &Arc<Vec<u8>>) {
        let (lock, condvar) = &*self.queue;
        let mut queue = lock.lock().unwrap();
        if queue.pending.contains(&key) {
            return;
        }
        queue.pending.insert(key);
        queue.requests.push_front(Request {
            key,
            bytes: Arc::clone(bytes),
        });
        while queue.requests.len() > QUEUE_LIMIT {
            if let Some(dropped) = queue.requests.pop_back() {
                queue.pending.remove(&dropped.key);
            }
        }
        condvar.notify_one();
    }
}

fn worker(
    queue: Arc<(Mutex<Queue>, Condvar)>,
    results: Sender<(TextureKey, Option<ColorImage>)>,
    ctx: egui::Context,
) {
    let mut documents: HashMap<DocumentKey, pdf_core::engine::Document> = HashMap::new();
    loop {
        let (request, live) = {
            let (lock, condvar) = &*queue;
            let mut guard = lock.lock().unwrap();
            loop {
                if let Some(request) = guard.requests.pop_front() {
                    break (request, guard.live_documents.clone());
                }
                guard = condvar.wait(guard).unwrap();
            }
        };
        documents.retain(|key, _| live.contains(key));
        if !live.contains(&request.key.document) {
            finish(&queue, request.key);
            continue;
        }
        let image = render(&mut documents, &request);
        finish(&queue, request.key);
        if results.send((request.key, image)).is_err() {
            return;
        }
        ctx.request_repaint();
    }
}

fn finish(queue: &Arc<(Mutex<Queue>, Condvar)>, key: TextureKey) {
    queue.0.lock().unwrap().pending.remove(&key);
}

fn render(
    documents: &mut HashMap<DocumentKey, pdf_core::engine::Document>,
    request: &Request,
) -> Option<ColorImage> {
    if !documents.contains_key(&request.key.document) {
        let document = pdf_core::engine::load(request.bytes.as_ref().clone(), None).ok()?;
        documents.insert(request.key.document, document);
    }
    let document = documents.get(&request.key.document)?;
    let page = document.pages().get(request.key.page as PdfPageIndex).ok()?;
    let config = PdfRenderConfig::new()
        .set_target_width(request.key.width_px.max(1) as Pixels)
        .render_form_data(true)
        .render_annotations(true)
        .use_lcd_text_rendering(false);
    let bitmap = page.render_with_config(&config).ok()?;
    let image = bitmap.as_image().ok()?.into_rgba8();
    let size = [image.width() as usize, image.height() as usize];
    Some(ColorImage::from_rgba_unmultiplied(size, image.as_raw()))
}

/// Rounds a requested pixel width up to a bucket so continuous zooming
/// doesn't trigger a render per frame.
pub fn bucketed_width(width_px: f32) -> u32 {
    let width = width_px.clamp(16.0, 8192.0);
    let step = if width < 512.0 { 32.0 } else if width < 2048.0 { 128.0 } else { 256.0 };
    ((width / step).ceil() * step) as u32
}
