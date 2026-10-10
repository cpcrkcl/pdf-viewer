//! The protected working copy and its revision history.
//!
//! Every mutation produces a complete, validated PDF snapshot. Undo and redo
//! restore earlier snapshots byte-for-byte, so dirty tracking is a plain
//! comparison against the snapshot taken when the document was opened.

use aes_gcm::{
    Aes256Gcm, KeyInit,
    aead::{Aead, AeadCore, OsRng},
};
use std::collections::{BTreeSet, HashMap, HashSet};
use std::io::Write;
use std::sync::Arc;

use lopdf::Document as LoDocument;

use crate::engine;
use crate::error::{CoreError, CoreResult};
use crate::ids::{WorkingPageId, sha256_hex};
use crate::structure;

#[derive(Debug, Clone)]
pub struct DocumentRevision {
    pub pdf_data: Arc<Vec<u8>>,
    pub page_ids: Vec<WorkingPageId>,
    digest: String,
}

impl DocumentRevision {
    fn new(pdf_data: Vec<u8>, page_ids: Vec<WorkingPageId>) -> Self {
        let digest = sha256_hex(&pdf_data);
        Self {
            pdf_data: Arc::new(pdf_data),
            page_ids,
            digest,
        }
    }
}

enum StoredRevision {
    Memory(DocumentRevision),
    Disk {
        file: Arc<tempfile::NamedTempFile>,
        page_ids: Vec<WorkingPageId>,
        digest: String,
    },
}

struct HistoryArchive {
    sender: std::sync::mpsc::SyncSender<(String, Arc<Vec<u8>>)>,
    results: std::sync::mpsc::Receiver<(String, CoreResult<Arc<tempfile::NamedTempFile>>)>,
    pending: HashSet<String>,
    failed: HashSet<String>,
}

impl HistoryArchive {
    fn new(cipher: Aes256Gcm) -> Self {
        let (sender, receiver) = std::sync::mpsc::sync_channel::<(String, Arc<Vec<u8>>)>(1);
        let (finished, results) = std::sync::mpsc::channel();
        std::thread::Builder::new()
            .name("pdf-undo-archive".into())
            .spawn(move || {
                while let Ok((digest, bytes)) = receiver.recv() {
                    let result = (|| {
                        let mut file = tempfile::Builder::new()
                            .prefix("pdfviewer-undo-")
                            .tempfile()?;
                        let nonce = Aes256Gcm::generate_nonce(&mut OsRng);
                        let encrypted = cipher
                            .encrypt(&nonce, bytes.as_slice())
                            .map_err(|_| CoreError::CouldNotCopyDocument)?;
                        file.write_all(&nonce)?;
                        file.write_all(&encrypted)?;
                        Ok(Arc::new(file))
                    })();
                    if finished.send((digest, result)).is_err() {
                        break;
                    }
                }
            })
            .expect("undo archive worker starts");
        Self {
            sender,
            results,
            pending: HashSet::new(),
            failed: HashSet::new(),
        }
    }
}

pub struct DocumentEditor {
    revisions: Vec<StoredRevision>,
    history_budget: usize,
    history_cipher: Aes256Gcm,
    history_archive: Option<HistoryArchive>,
    snapshot_index: usize,
    source_digest: String,
    protected_digests: HashSet<String>,
    /// Monotonic counter bumped whenever the visible document changes, so
    /// renderers can cache per revision without hashing bytes.
    generation: u64,
}

impl DocumentEditor {
    /// Builds an editor from an unencrypted, already-normalized working copy.
    pub fn new(working_copy: Vec<u8>, document_fingerprint: &str) -> CoreResult<Self> {
        let count = validated_page_count(&working_copy)?;
        let page_ids = (0..count)
            .map(|index| WorkingPageId::original(document_fingerprint, index))
            .collect();
        let revision = DocumentRevision::new(working_copy, page_ids);
        let source_digest = revision.digest.clone();
        Ok(Self {
            revisions: vec![StoredRevision::Memory(revision)],
            history_budget: 256 * 1024 * 1024,
            history_cipher: Aes256Gcm::new(&Aes256Gcm::generate_key(&mut OsRng)),
            history_archive: None,
            snapshot_index: 0,
            protected_digests: HashSet::from([source_digest.clone()]),
            source_digest,
            generation: 0,
        })
    }

    pub fn current(&self) -> &DocumentRevision {
        match &self.revisions[self.snapshot_index] {
            StoredRevision::Memory(revision) => revision,
            StoredRevision::Disk { .. } => unreachable!("current revision is always resident"),
        }
    }

    pub fn pdf_data(&self) -> Arc<Vec<u8>> {
        Arc::clone(&self.current().pdf_data)
    }

    pub fn page_ids(&self) -> &[WorkingPageId] {
        &self.current().page_ids
    }

    pub fn page_count(&self) -> usize {
        self.page_ids().len()
    }

    pub fn generation(&self) -> u64 {
        self.generation
    }

    pub fn page_id(&self, index: usize) -> Option<&WorkingPageId> {
        self.page_ids().get(index)
    }

    pub fn index_of(&self, page_id: &WorkingPageId) -> Option<usize> {
        self.page_ids()
            .iter()
            .position(|candidate| candidate == page_id)
    }

    pub fn can_undo(&self) -> bool {
        self.snapshot_index > 0
    }

    pub fn can_redo(&self) -> bool {
        self.snapshot_index + 1 < self.revisions.len()
    }

    /// The working copy differs from the document as opened.
    pub fn is_dirty(&self) -> bool {
        self.current().digest != self.source_digest
    }

    /// The current revision has been neither opened nor exported.
    pub fn has_unexported_changes(&self) -> bool {
        !self.protected_digests.contains(&self.current().digest)
    }

    /// Parses the current revision for object-level reads.
    pub fn parse(&self) -> CoreResult<LoDocument> {
        structure::parse(&self.current().pdf_data)
    }

    pub fn delete_pages(&mut self, indexes: &[usize]) -> CoreResult<()> {
        let indexes = self.validated(indexes)?;
        if indexes.len() >= self.page_count() {
            return Err(CoreError::CannotDeleteOnlyPage);
        }
        let remaining_ids: Vec<WorkingPageId> = self
            .page_ids()
            .iter()
            .enumerate()
            .filter(|(index, _)| !indexes.contains(index))
            .map(|(_, id)| id.clone())
            .collect();
        self.mutate_structure(remaining_ids, |document| {
            let pages = structure::page_ids(document);
            let kept: Vec<_> = pages
                .iter()
                .enumerate()
                .filter(|(index, _)| !indexes.contains(index))
                .map(|(_, page)| *page)
                .collect();
            structure::set_page_order(document, &kept)
        })
    }

    pub fn rotate_pages(&mut self, indexes: &[usize], clockwise: bool) -> CoreResult<()> {
        let indexes = self.validated(indexes)?;
        let delta = if clockwise { 90 } else { -90 };
        let ids = self.page_ids().to_vec();
        self.mutate_structure(ids, |document| {
            let pages = structure::page_ids(document);
            for index in &indexes {
                let page = pages[*index];
                let rotation = structure::rotation(document, page);
                structure::set_rotation(document, page, rotation + delta)?;
            }
            Ok(())
        })
    }

    /// Moves the selected pages, preserving their relative order, so the
    /// first selected page lands before the page currently at `destination`.
    pub fn move_pages(&mut self, indexes: &[usize], destination: usize) -> CoreResult<()> {
        let indexes = self.validated(indexes)?;
        if destination > self.page_count() {
            return Err(CoreError::InvalidInsertionIndex);
        }
        let order = reordered((0..self.page_count()).collect(), &indexes, destination)?;
        let ids: Vec<WorkingPageId> = order
            .iter()
            .map(|index| self.page_ids()[*index].clone())
            .collect();
        self.mutate_structure(ids, |document| {
            let pages = structure::page_ids(document);
            let reordered_pages: Vec<_> = order.iter().map(|index| pages[*index]).collect();
            structure::set_page_order(document, &reordered_pages)
        })
    }

    /// Inserts pages from another (unlocked, unencrypted) PDF.
    pub fn insert_pages(
        &mut self,
        source_pdf: &[u8],
        source_indexes: Option<&[usize]>,
        source_fingerprint: Option<&str>,
        at: usize,
    ) -> CoreResult<()> {
        let source = structure::parse(source_pdf)?;
        let source_count = structure::page_count(&source);
        if source_count == 0 {
            return Err(CoreError::NoPagesToInsert);
        }
        if at > self.page_count() {
            return Err(CoreError::InvalidInsertionIndex);
        }
        let selected: Vec<usize> = match source_indexes {
            Some(indexes) => validated_selection(indexes, source_count)?
                .into_iter()
                .collect(),
            None => (0..source_count).collect(),
        };
        let fingerprint = source_fingerprint
            .map(str::to_owned)
            .unwrap_or_else(|| sha256_hex(source_pdf));
        let mut ids = self.page_ids().to_vec();
        for (offset, source_index) in selected.iter().enumerate() {
            ids.insert(
                at + offset,
                WorkingPageId::inserted(&fingerprint, *source_index),
            );
        }
        self.mutate_structure(ids, move |document| {
            structure::import_pages(document, source, &selected, at).map(|_| ())
        })
    }

    /// A standalone PDF containing only the selected pages.
    pub fn extract_pages(&self, indexes: &[usize]) -> CoreResult<Vec<u8>> {
        let indexes = self.validated(indexes)?;
        let mut document = self.parse()?;
        structure::flatten_page_tree(&mut document)?;
        let pages = structure::page_ids(&document);
        let kept: Vec<_> = indexes.iter().map(|index| pages[*index]).collect();
        structure::set_page_order(&mut document, &kept)?;
        document.prune_objects();
        let bytes = structure::serialize(&mut document)?;
        validated_page_count(&bytes)?;
        Ok(bytes)
    }

    /// Commits an arbitrary object-level change that keeps page identities.
    pub fn mutate<F>(&mut self, body: F) -> CoreResult<()>
    where
        F: FnOnce(&mut LoDocument) -> CoreResult<()>,
    {
        let ids = self.page_ids().to_vec();
        let mut document = self.parse()?;
        body(&mut document)?;
        // Replaced appearance streams and deleted annotations become garbage.
        document.prune_objects();
        let bytes = structure::serialize(&mut document)?;
        self.commit(bytes, ids)
    }

    /// Replaces the working copy with a processed document (OCR, redaction,
    /// enhancement). `source_page_indexes[i]` names the working page that
    /// produced processed page `i`; a repeated index (a split scan) gets a
    /// fresh identity for each extra occurrence.
    pub fn apply_processed_document(
        &mut self,
        processed: Vec<u8>,
        source_page_indexes: Option<&[usize]>,
    ) -> CoreResult<()> {
        let processed_count = validated_page_count(&processed)?;
        let Some(source_page_indexes) = source_page_indexes else {
            if processed_count != self.page_count() {
                return Err(CoreError::CouldNotCopyDocument);
            }
            let ids = self.page_ids().to_vec();
            return self.commit(processed, ids);
        };
        let covered: BTreeSet<usize> = source_page_indexes.iter().copied().collect();
        let sorted = source_page_indexes
            .windows(2)
            .all(|pair| pair[0] <= pair[1]);
        if processed_count != source_page_indexes.len()
            || !sorted
            || covered != (0..self.page_count()).collect()
        {
            return Err(CoreError::CouldNotCopyDocument);
        }
        let mut occurrences: HashMap<usize, usize> = HashMap::new();
        let ids = source_page_indexes
            .iter()
            .map(|source_index| {
                let occurrence = occurrences.entry(*source_index).or_default();
                *occurrence += 1;
                let source_id = &self.page_ids()[*source_index];
                if *occurrence == 1 {
                    source_id.clone()
                } else {
                    WorkingPageId::inserted(
                        &source_id.document_fingerprint,
                        source_id.original_page_index,
                    )
                }
            })
            .collect();
        self.commit(processed, ids)
    }

    pub fn recovered_without_source(&mut self, page_ids: Vec<WorkingPageId>) -> CoreResult<()> {
        if page_ids.len() != self.page_count() {
            return Err(CoreError::CouldNotCopyDocument);
        }
        let StoredRevision::Memory(revision) = &mut self.revisions[self.snapshot_index] else {
            unreachable!()
        };
        revision.page_ids = page_ids;
        self.source_digest.clear();
        self.protected_digests.clear();
        Ok(())
    }

    /// Restores an autosaved working copy while retaining the original undo baseline.
    pub fn recover(&mut self, bytes: Vec<u8>, page_ids: Vec<WorkingPageId>) -> CoreResult<()> {
        self.commit(bytes, page_ids)
    }

    pub fn undo(&mut self) -> CoreResult<()> {
        if !self.can_undo() {
            return Err(CoreError::NothingToUndo);
        }
        self.restore_revision(self.snapshot_index - 1)?;
        self.snapshot_index -= 1;
        self.spill_history();
        self.generation += 1;
        Ok(())
    }

    pub fn redo(&mut self) -> CoreResult<()> {
        if !self.can_redo() {
            return Err(CoreError::NothingToRedo);
        }
        self.restore_revision(self.snapshot_index + 1)?;
        self.snapshot_index += 1;
        self.spill_history();
        self.generation += 1;
        Ok(())
    }

    pub fn mark_current_revision_exported(&mut self) {
        let digest = self.current().digest.clone();
        self.protected_digests.insert(digest);
    }

    fn mutate_structure<F>(&mut self, ids: Vec<WorkingPageId>, body: F) -> CoreResult<()>
    where
        F: FnOnce(&mut LoDocument) -> CoreResult<()>,
    {
        let mut document = self.parse()?;
        structure::flatten_page_tree(&mut document)?;
        body(&mut document)?;
        document.prune_objects();
        let bytes = structure::serialize(&mut document)?;
        self.commit(bytes, ids)
    }

    fn commit(&mut self, bytes: Vec<u8>, ids: Vec<WorkingPageId>) -> CoreResult<()> {
        if validated_page_count(&bytes)? != ids.len() {
            return Err(CoreError::CouldNotCopyDocument);
        }
        let revision = DocumentRevision::new(bytes, ids);
        if revision.digest == self.current().digest && revision.page_ids == self.current().page_ids
        {
            return Ok(());
        }
        self.revisions.truncate(self.snapshot_index + 1);
        self.revisions.push(StoredRevision::Memory(revision));
        self.snapshot_index += 1;
        self.generation += 1;
        self.spill_history();
        Ok(())
    }

    /// Resident snapshot bytes. Large histories retain every undo step on disk.
    pub fn history_memory_bytes(&self) -> usize {
        self.revisions
            .iter()
            .map(|revision| match revision {
                StoredRevision::Memory(revision) => revision.pdf_data.len(),
                StoredRevision::Disk { .. } => 0,
            })
            .sum()
    }

    fn restore_revision(&mut self, index: usize) -> CoreResult<()> {
        if let StoredRevision::Disk {
            file,
            page_ids,
            digest,
        } = &self.revisions[index]
        {
            let encrypted = std::fs::read(file.path())?;
            if encrypted.len() < 12 {
                return Err(CoreError::CouldNotCopyDocument);
            }
            let bytes = self
                .history_cipher
                .decrypt(
                    aes_gcm::Nonce::from_slice(&encrypted[..12]),
                    &encrypted[12..],
                )
                .map_err(|_| CoreError::CouldNotCopyDocument)?;
            if sha256_hex(&bytes) != *digest {
                return Err(CoreError::CouldNotCopyDocument);
            }
            let restored = DocumentRevision {
                pdf_data: Arc::new(bytes),
                page_ids: page_ids.clone(),
                digest: digest.clone(),
            };
            self.revisions[index] = StoredRevision::Memory(restored);
        }
        Ok(())
    }

    /// Poll once per UI frame. Archiving never encrypts or writes on the UI thread.
    pub fn poll_history(&mut self) {
        self.spill_history();
    }
    pub fn history_is_archiving(&self) -> bool {
        self.history_archive
            .as_ref()
            .is_some_and(|archive| !archive.pending.is_empty())
    }

    fn spill_history(&mut self) {
        if let Some(archive) = &mut self.history_archive {
            while let Ok((digest, result)) = archive.results.try_recv() {
                archive.pending.remove(&digest);
                match result {
                    Ok(file) => {
                        for (index, stored) in self.revisions.iter_mut().enumerate() {
                            if index == self.snapshot_index || index + 1 == self.snapshot_index {
                                continue;
                            }
                            if let StoredRevision::Memory(revision) = stored
                                && revision.digest == digest
                            {
                                *stored = StoredRevision::Disk {
                                    file: Arc::clone(&file),
                                    page_ids: revision.page_ids.clone(),
                                    digest: revision.digest.clone(),
                                };
                            }
                        }
                    }
                    Err(_) => {
                        archive.failed.insert(digest);
                    } // Keep in memory if disk is unavailable.
                }
            }
        }
        let mut resident = self.history_memory_bytes();
        if resident <= self.history_budget {
            return;
        }
        let archive = self
            .history_archive
            .get_or_insert_with(|| HistoryArchive::new(self.history_cipher.clone()));
        for (index, stored) in self.revisions.iter().enumerate() {
            if index == self.snapshot_index || index + 1 == self.snapshot_index {
                continue;
            }
            let StoredRevision::Memory(revision) = stored else {
                continue;
            };
            if archive.pending.contains(&revision.digest) {
                resident = resident.saturating_sub(revision.pdf_data.len());
                continue;
            }
            if resident <= self.history_budget {
                break;
            }
            if archive.failed.contains(&revision.digest) {
                continue;
            }
            match archive
                .sender
                .try_send((revision.digest.clone(), Arc::clone(&revision.pdf_data)))
            {
                Ok(()) => {
                    archive.pending.insert(revision.digest.clone());
                    resident = resident.saturating_sub(revision.pdf_data.len());
                }
                Err(_) => break,
            }
        }
    }

    fn validated(&self, indexes: &[usize]) -> CoreResult<BTreeSet<usize>> {
        validated_selection(indexes, self.page_count())
    }
}

fn validated_selection(indexes: &[usize], count: usize) -> CoreResult<BTreeSet<usize>> {
    if indexes.is_empty() || indexes.iter().any(|index| *index >= count) {
        return Err(CoreError::InvalidPageSelection);
    }
    Ok(indexes.iter().copied().collect())
}

fn reordered(
    items: Vec<usize>,
    selected: &BTreeSet<usize>,
    destination: usize,
) -> CoreResult<Vec<usize>> {
    let picked: Vec<usize> = selected.iter().map(|index| items[*index]).collect();
    let remaining: Vec<usize> = items
        .iter()
        .enumerate()
        .filter(|(index, _)| !selected.contains(index))
        .map(|(_, item)| *item)
        .collect();
    let adjusted = destination
        - selected
            .iter()
            .filter(|index| **index < destination)
            .count();
    if adjusted > remaining.len() {
        return Err(CoreError::InvalidInsertionIndex);
    }
    let mut result = remaining[..adjusted].to_vec();
    result.extend(picked);
    result.extend_from_slice(&remaining[adjusted..]);
    Ok(result)
}

/// A snapshot is valid when both the object model and the renderer accept it.
pub fn validated_page_count(bytes: &[u8]) -> CoreResult<usize> {
    let count = structure::page_count(
        &structure::parse(bytes).map_err(|_| CoreError::CouldNotCopyDocument)?,
    );
    let rendered =
        engine::load_nonempty(bytes.to_vec(), None).map_err(|_| CoreError::CouldNotCopyDocument)?;
    if count == 0 || rendered.pages().len() as usize != count {
        return Err(CoreError::CouldNotCopyDocument);
    }
    Ok(count)
}

#[cfg(test)]
mod tests {
    use super::reordered;
    use std::collections::BTreeSet;

    #[test]
    fn reorder_matches_swift_semantics() {
        let items: Vec<usize> = (0..5).collect();
        let selection = BTreeSet::from([1, 3]);
        assert_eq!(
            reordered(items.clone(), &selection, 0).unwrap(),
            vec![1, 3, 0, 2, 4]
        );
        assert_eq!(
            reordered(items.clone(), &selection, 5).unwrap(),
            vec![0, 2, 4, 1, 3]
        );
        assert_eq!(
            reordered(items, &selection, 3).unwrap(),
            vec![0, 2, 1, 3, 4]
        );
    }
}

#[cfg(test)]
mod history_tests {
    use super::*;
    #[test]
    fn disk_history_keeps_all_steps_and_dirty_tracking() {
        let mut editor = DocumentEditor::new(crate::testing::numbered_pdf(2), "history").unwrap();
        editor.history_budget = 1;
        let original = editor.pdf_data();
        editor.rotate_pages(&[0], true).unwrap();
        let rotated = editor.pdf_data();
        editor.mark_current_revision_exported();
        editor.rotate_pages(&[1], true).unwrap();
        editor.rotate_pages(&[0], true).unwrap();
        for _ in 0..100 {
            editor.poll_history();
            if editor
                .revisions
                .iter()
                .any(|r| matches!(r, StoredRevision::Disk { .. }))
            {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(2));
        }
        assert!(
            editor
                .revisions
                .iter()
                .any(|r| matches!(r, StoredRevision::Disk { .. }))
        );
        editor.undo().unwrap();
        editor.undo().unwrap();
        assert_eq!(*editor.pdf_data(), *rotated);
        assert!(!editor.has_unexported_changes());
        editor.undo().unwrap();
        assert_eq!(*editor.pdf_data(), *original);
        assert!(!editor.is_dirty());
        editor.redo().unwrap();
        assert_eq!(*editor.pdf_data(), *rotated);
        editor.rotate_pages(&[0], false).unwrap();
        assert!(!editor.can_redo());
    }
}

#[cfg(test)]
mod memory_benchmark {
    use super::*;
    #[test]
    #[ignore = "manual performance benchmark"]
    fn undo_memory_benchmark() {
        let bytes = crate::testing::image_pdf(600, 800);
        for budget in [usize::MAX, 2 * 1024 * 1024] {
            let mut editor = DocumentEditor::new(bytes.clone(), "benchmark").unwrap();
            editor.history_budget = budget;
            let start = std::time::Instant::now();
            for _ in 0..20 {
                editor.rotate_pages(&[0], true).unwrap();
            }
            let edits = start.elapsed();
            let archive_start = std::time::Instant::now();
            for _ in 0..1000 {
                editor.poll_history();
                if editor.history_memory_bytes() <= budget.max(editor.pdf_data().len() * 2 + 4096) {
                    break;
                }
                std::thread::sleep(std::time::Duration::from_millis(2));
            }
            eprintln!(
                "history budget {budget}: resident {} bytes; 20 edits {edits:?}; archive settled {:?}",
                editor.history_memory_bytes(),
                archive_start.elapsed()
            );
            for _ in 0..20 {
                editor.undo().unwrap();
            }
            assert_eq!(*editor.pdf_data(), bytes);
        }
    }
}
