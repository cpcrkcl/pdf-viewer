//! Background page rendering.
//!
//! A single worker thread owns the PDFium documents it renders from (PDFium
//! serializes calls anyway). The UI queues requests every frame for the pages
//! it needs; the newest requests are served first and stale generations are
//! dropped, so scrolling and zooming stay responsive on large documents.

use std::collections::{HashMap, HashSet, VecDeque};
use std::sync::mpsc::{Receiver, SyncSender, sync_channel};
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

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum RenderPriority {
    Thumbnail,
    Prefetch,
    Visible,
    Preview,
}

struct Request {
    priority: RenderPriority,
    frame: u64,
    full_width: Option<u32>,
    key: TextureKey,
    bytes: Arc<Vec<u8>>,
}

#[derive(Default)]
struct Queue {
    requests: VecDeque<Request>,
    pending: HashSet<TextureKey>,
    live_documents: HashSet<DocumentKey>,
    shutdown: bool,
    inflight: Option<TextureKey>,
}

pub struct RenderService {
    queue: Arc<(Mutex<Queue>, Condvar)>,
    results: Receiver<(TextureKey, Option<ColorImage>)>,
    textures: HashMap<TextureKey, (TextureHandle, u64, usize)>,
    failed: HashSet<TextureKey>,
    frame: u64,
    live: HashSet<DocumentKey>,
}

const TEXTURE_BUDGET: usize = 192 * 1024 * 1024;
const QUEUE_LIMIT: usize = 64;

impl RenderService {
    pub fn new(ctx: egui::Context) -> Self {
        let queue: Arc<(Mutex<Queue>, Condvar)> = Arc::default();
        let (sender, results) = sync_channel(3);
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
            live: HashSet::new(),
        }
    }

    /// Uploads finished renders and evicts least-recently-used textures.
    pub fn begin_frame(&mut self, ctx: &egui::Context) {
        self.frame += 1;
        for _ in 0..3 {
            let Ok((key, image)) = self.results.try_recv() else {
                break;
            };
            if !self.live.contains(&key.document) {
                continue;
            }
            match image {
                Some(image) => {
                    let name = format!(
                        "page-{}-{}-{}-{}",
                        key.document.tab, key.document.generation, key.page, key.width_px
                    );
                    let memory = image.size[0] * image.size[1] * 4;
                    let handle = ctx.load_texture(name, image, TextureOptions::LINEAR);
                    self.textures.insert(key, (handle, self.frame, memory));
                }
                None => {
                    self.failed.insert(key);
                }
            }
        }
        let mut memory: usize = self.textures.values().map(|(_, _, bytes)| bytes).sum();
        if memory > TEXTURE_BUDGET {
            let mut by_age: Vec<_> = self
                .textures
                .iter()
                .map(|(key, (_, used, _))| (*used, *key))
                .collect();
            by_age.sort_unstable_by_key(|(used, _)| *used);
            for (_, key) in by_age {
                if memory <= TEXTURE_BUDGET {
                    break;
                }
                if let Some((_, _, bytes)) = self.textures.remove(&key) {
                    memory -= bytes;
                }
            }
        }
        // Discard queued work that hasn't been wanted for two frames.
        let mut queue = self.queue.0.lock().unwrap();
        let frame = self.frame;
        queue.requests.retain(|request| request.frame + 2 >= frame);
        let queued: HashSet<_> = queue.requests.iter().map(|request| request.key).collect();
        let inflight = queue.inflight;
        queue
            .pending
            .retain(|key| queued.contains(key) || Some(*key) == inflight);
    }

    pub fn carry_forward(
        &mut self,
        old: DocumentKey,
        new: DocumentKey,
        unchanged: &HashSet<usize>,
    ) {
        let retained: Vec<_> = self
            .textures
            .iter()
            .filter(|(key, _)| key.document == old && unchanged.contains(&key.page))
            .map(|(key, value)| {
                (
                    TextureKey {
                        document: new,
                        ..*key
                    },
                    value.clone(),
                )
            })
            .collect();
        self.textures.extend(retained);
    }

    /// Declares which documents are still open; others are released.
    pub fn retain_documents(&mut self, live: HashSet<DocumentKey>) {
        self.textures.retain(|key, _| live.contains(&key.document));
        self.failed.retain(|key| live.contains(&key.document));
        self.live = live.clone();
        let (lock, _) = &*self.queue;
        let mut queue = lock.lock().unwrap();
        queue.live_documents = live;
        queue
            .requests
            .retain(|request| self.live.contains(&request.key.document));
        self.queue.1.notify_one();
    }

    /// The exact texture if ready, otherwise the closest-width texture for the
    /// same page and revision as a placeholder.
    /// Queues a render when the exact texture is missing.
    pub fn texture(&mut self, key: TextureKey, bytes: &Arc<Vec<u8>>) -> Option<TextureHandle> {
        self.texture_with_priority(key, bytes, RenderPriority::Thumbnail)
    }

    pub fn texture_with_priority(
        &mut self,
        key: TextureKey,
        bytes: &Arc<Vec<u8>>,
        priority: RenderPriority,
    ) -> Option<TextureHandle> {
        if let Some((handle, used, _)) = self.textures.get_mut(&key) {
            *used = self.frame;
            return Some(handle.clone());
        }
        let closest = self
            .textures
            .keys()
            .filter(|candidate| candidate.document == key.document && candidate.page == key.page)
            .min_by_key(|candidate| candidate.width_px.abs_diff(key.width_px))
            .copied();
        // A small first pass makes a blank visible page readable quickly.
        let preview = TextureKey {
            width_px: 512,
            ..key
        };
        let request_key = if closest.is_none()
            && !self.failed.contains(&preview)
            && priority == RenderPriority::Visible
            && key.width_px > 768
        {
            TextureKey {
                width_px: 512,
                ..key
            }
        } else {
            key
        };
        let request_priority = if request_key != key {
            RenderPriority::Preview
        } else {
            priority
        };
        if !self.failed.contains(&request_key) {
            self.request(
                request_key,
                bytes,
                request_priority,
                (request_key != key).then_some(key.width_px),
            );
        }
        closest
            .and_then(|candidate| self.textures.get_mut(&candidate))
            .map(|(handle, used, _)| {
                *used = self.frame;
                handle.clone()
            })
    }

    fn request(
        &self,
        key: TextureKey,
        bytes: &Arc<Vec<u8>>,
        priority: RenderPriority,
        full_width: Option<u32>,
    ) {
        let (lock, condvar) = &*self.queue;
        let mut queue = lock.lock().unwrap();
        if let Some(request) = queue.requests.iter_mut().find(|request| request.key == key) {
            request.frame = self.frame;
            request.priority = request.priority.max(priority);
            return;
        }
        if !queue.pending.insert(key) {
            return;
        }
        queue.requests.push_front(Request {
            key,
            bytes: Arc::clone(bytes),
            priority,
            frame: self.frame,
            full_width,
        });
        while queue.requests.len() > QUEUE_LIMIT {
            let index = queue
                .requests
                .iter()
                .enumerate()
                .min_by_key(|(_, request)| (request.priority, request.frame))
                .map(|(index, _)| index)
                .unwrap();
            if let Some(dropped) = queue.requests.remove(index) {
                queue.pending.remove(&dropped.key);
            }
        }
        condvar.notify_one();
    }
}

impl Drop for RenderService {
    fn drop(&mut self) {
        let (lock, condvar) = &*self.queue;
        lock.lock().unwrap().shutdown = true;
        condvar.notify_one();
    }
}

fn worker(
    queue: Arc<(Mutex<Queue>, Condvar)>,
    results: SyncSender<(TextureKey, Option<ColorImage>)>,
    ctx: egui::Context,
) {
    let mut documents: HashMap<DocumentKey, pdf_core::engine::Document> = HashMap::new();
    loop {
        let (mut request, live) = {
            let (lock, condvar) = &*queue;
            let mut guard = lock.lock().unwrap();
            loop {
                if guard.shutdown {
                    return;
                }
                let index = guard
                    .requests
                    .iter()
                    .enumerate()
                    .max_by_key(|(_, request)| (request.priority, request.frame))
                    .map(|(index, _)| index);
                if let Some(request) = index.and_then(|index| guard.requests.remove(index)) {
                    guard.inflight = Some(request.key);
                    break (request, guard.live_documents.clone());
                }
                documents.retain(|key, _| guard.live_documents.contains(key));
                guard = condvar.wait(guard).unwrap();
            }
        };
        documents.retain(|key, _| live.contains(key));
        if !live.contains(&request.key.document) {
            finish(&queue, request.key);
            continue;
        }
        let pending_key = request.key;
        let image = render(&mut documents, &mut request);
        if results.send((request.key, image)).is_err() {
            return;
        }
        finish(&queue, pending_key);
        ctx.request_repaint();
    }
}

fn finish(queue: &Arc<(Mutex<Queue>, Condvar)>, key: TextureKey) {
    let mut guard = queue.0.lock().unwrap();
    guard.pending.remove(&key);
    guard.inflight = None;
}

fn render(
    documents: &mut HashMap<DocumentKey, pdf_core::engine::Document>,
    request: &mut Request,
) -> Option<ColorImage> {
    if let std::collections::hash_map::Entry::Vacant(entry) = documents.entry(request.key.document)
    {
        let document = pdf_core::engine::load(request.bytes.as_ref().clone(), None).ok()?;
        entry.insert(document);
    }
    let document = documents.get(&request.key.document)?;
    let page = document
        .pages()
        .get(request.key.page as PdfPageIndex)
        .ok()?;
    // Image decoding dominates scans: the release benchmark showed that
    // a second render almost doubles total work for a small latency gain.
    if let Some(width) = request.full_width
        && page.text().is_ok_and(|text| text.is_empty())
    {
        request.key.width_px = width;
    }
    let aspect = page.height().value / page.width().value.max(1.0);
    let width = request
        .key
        .width_px
        .max(1)
        .min((16_000_000.0_f32 / aspect.max(0.01)).sqrt() as u32);
    let config = PdfRenderConfig::new()
        .set_target_width(width.max(1) as Pixels)
        .set_maximum_width(8192)
        .set_maximum_height(8192)
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
    let step = if width < 512.0 {
        32.0
    } else if width < 2048.0 {
        128.0
    } else {
        256.0
    };
    ((width / step).ceil() * step) as u32
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Instant;
    #[test]
    fn visible_work_outranks_prefetch_and_thumbnail() {
        let ctx = egui::Context::default();
        let service = RenderService::new(ctx);
        let bytes = Arc::new(Vec::new());
        let document = DocumentKey {
            tab: 1,
            generation: 0,
        };
        // Keep the worker asleep by testing the queue ordering directly.
        let mut queue = Queue::default();
        for (page, priority) in [
            (0, RenderPriority::Visible),
            (1, RenderPriority::Prefetch),
            (2, RenderPriority::Thumbnail),
        ] {
            queue.requests.push_front(Request {
                key: TextureKey {
                    document,
                    page,
                    width_px: 512,
                },
                bytes: bytes.clone(),
                priority,
                frame: 1,
                full_width: None,
            });
        }
        let request = queue
            .requests
            .iter()
            .max_by_key(|request| (request.priority, request.frame))
            .unwrap();
        assert_eq!(request.key.page, 0);
        drop(service);
    }
    #[test]
    fn scans_skip_preview_but_text_pages_use_it() {
        for (bytes, expected) in [
            (pdf_core::testing::image_pdf(64, 64), 1024),
            (pdf_core::testing::text_pdf(&["text"]), 512),
        ] {
            let key = TextureKey {
                document: DocumentKey {
                    tab: 1,
                    generation: 0,
                },
                page: 0,
                width_px: 512,
            };
            let mut request = Request {
                priority: RenderPriority::Preview,
                frame: 1,
                full_width: Some(1024),
                key,
                bytes: Arc::new(bytes),
            };
            let image = render(&mut HashMap::new(), &mut request).unwrap();
            assert_eq!(request.key.width_px, expected);
            assert_eq!(image.size[0], expected as usize);
        }
    }

    #[test]
    #[ignore = "manual performance benchmark"]
    fn preview_render_benchmark() {
        for (name, bytes) in [
            ("text", pdf_core::testing::numbered_pdf(20)),
            ("scan", pdf_core::testing::image_pdf(2000, 2600)),
        ] {
            let document = DocumentKey {
                tab: 1,
                generation: 0,
            };
            let mut documents = HashMap::new();
            documents.insert(
                document,
                pdf_core::engine::load(bytes.clone(), None).unwrap(),
            );
            let mut totals = Vec::new();
            for width_px in [512, 2304] {
                let mut request = Request {
                    key: TextureKey {
                        document,
                        page: 0,
                        width_px,
                    },
                    bytes: Arc::new(bytes.clone()),
                    priority: RenderPriority::Visible,
                    frame: 1,
                    full_width: None,
                };
                let start = Instant::now();
                for _ in 0..12 {
                    std::hint::black_box(render(&mut documents, &mut request).unwrap());
                }
                totals.push(start.elapsed());
            }
            eprintln!(
                "{name}: 12 previews {:?}; 12 full renders {:?}",
                totals[0], totals[1]
            );
        }
    }
}
