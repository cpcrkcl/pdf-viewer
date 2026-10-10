//! Atomic session checkpoints, with protected recovery PDFs re-encrypted.
//! One worker coalesces requests so autosave never runs on the drawing thread.
use crate::reader_state::{MAX_ZOOM, MIN_ZOOM, ReaderState, Zoom};
use pdf_core::persistence::{JsonFile, write_atomically};
use pdf_core::{CoreError, WorkingPageId};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use std::sync::{
    Arc, Condvar, Mutex,
    mpsc::{Receiver, channel},
};

#[derive(Clone, Serialize, Deserialize)]
pub struct SavedTab {
    pub source: PathBuf,
    pub fingerprint: String,
    #[serde(default = "default_security")]
    pub security: pdf_core::loader::SecurityContext,
    pub reader: ReaderState,
    pub snapshot: Option<String>,
    #[serde(default = "default_unexported")]
    pub unexported: bool,
    pub page_ids: Vec<WorkingPageId>,
}

fn default_unexported() -> bool {
    true
}

fn default_security() -> pdf_core::loader::SecurityContext {
    pdf_core::loader::SecurityContext::UNPROTECTED
}

#[derive(Clone, Default, Serialize, Deserialize)]
pub struct SavedSession {
    pub tabs: Vec<SavedTab>,
    pub active: Option<PathBuf>,
}

pub struct Checkpoint {
    pub session: SavedSession,
    pub documents: Vec<Option<RecoveryPdf>>,
}

pub struct RecoveryPdf {
    pub bytes: Arc<Vec<u8>>,
    pub password: Option<String>,
    pub permissions: pdf_core::loader::AccessPermissions,
}

#[derive(Default)]
struct Queue {
    pending: Option<Checkpoint>,
    stop: bool,
}

pub struct SessionStore {
    directory: PathBuf,
    queue: Arc<(Mutex<Queue>, Condvar)>,
    errors: Receiver<String>,
    worker: Option<std::thread::JoinHandle<()>>,
}

impl SessionStore {
    pub fn new(directory: PathBuf) -> Self {
        let queue: Arc<(Mutex<Queue>, Condvar)> = Arc::default();
        let (sender, errors) = channel();
        let worker_queue = Arc::clone(&queue);
        let worker_directory = directory.clone();
        let worker = std::thread::Builder::new()
            .name("pdf-autosave".into())
            .spawn(move || {
                loop {
                    let checkpoint = {
                        let (lock, wake) = &*worker_queue;
                        let mut state = lock.lock().unwrap();
                        while state.pending.is_none() && !state.stop {
                            state = wake.wait(state).unwrap();
                        }
                        if state.pending.is_none() && state.stop {
                            return;
                        }
                        state.pending.take().unwrap()
                    };
                    if let Err(error) = save_checkpoint(&worker_directory, checkpoint) {
                        let _ = sender.send(error.to_string());
                    }
                }
            })
            .expect("autosave worker starts");
        Self {
            directory,
            queue,
            errors,
            worker: Some(worker),
        }
    }

    pub fn load(&self) -> SavedSession {
        JsonFile::new(self.directory.join("session.json"))
            .load()
            .unwrap_or_default()
    }

    pub fn snapshot_path(&self, saved: &SavedTab) -> Option<PathBuf> {
        saved
            .snapshot
            .as_ref()
            .filter(|name| valid_snapshot_name(name))
            .map(|name| self.directory.join(name))
    }

    pub fn opening_path(&self, saved: &SavedTab) -> PathBuf {
        if saved.source.exists() {
            saved.source.clone()
        } else {
            self.snapshot_path(saved)
                .filter(|path| path.exists())
                .unwrap_or_else(|| saved.source.clone())
        }
    }

    pub fn request(&self, checkpoint: Checkpoint) {
        let (lock, wake) = &*self.queue;
        lock.lock().unwrap().pending = Some(checkpoint);
        wake.notify_one();
    }

    pub fn error(&self) -> Option<String> {
        self.errors.try_recv().ok()
    }

    pub fn recover(
        &self,
        session: &mut pdf_core::DocumentSession,
        saved: &SavedTab,
    ) -> Result<(), CoreError> {
        if session.fingerprint != saved.fingerprint {
            return Err(CoreError::Io("The original PDF changed since recovery was saved. Its recovered copy was kept for review.".into()));
        }
        let Some(name) = &saved.snapshot else {
            return Ok(());
        };
        if !valid_snapshot_name(name) {
            return Err(CoreError::InvalidPdf);
        }
        let encrypted = std::fs::read(self.directory.join(name))?;
        let opened = pdf_core::loader::open_bytes(encrypted, session.source_path.clone())?;
        let recovered = match opened {
            pdf_core::loader::OpenResult::Opened(recovered) => recovered,
            pdf_core::loader::OpenResult::PasswordRequired(mut locked) => locked
                .unlock(
                    session
                        .session_password()
                        .ok_or(CoreError::PasswordRequired)?,
                )?
                .ok_or(CoreError::PasswordRequired)?,
        };
        let bytes = recovered.editor.pdf_data().as_ref().clone();
        session.editor.recover(bytes, saved.page_ids.clone())?;
        if !saved.unexported {
            session.editor.mark_current_revision_exported();
        }
        Ok(())
    }

    pub fn finish(&mut self) {
        let (lock, wake) = &*self.queue;
        lock.lock().unwrap().stop = true;
        wake.notify_one();
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}

impl Drop for SessionStore {
    fn drop(&mut self) {
        self.finish();
    }
}

fn valid_snapshot_name(name: &str) -> bool {
    name.strip_suffix(".pdf")
        .is_some_and(|digest| digest.len() == 64 && digest.chars().all(|c| c.is_ascii_hexdigit()))
}

pub fn normalized_reader(mut reader: ReaderState, count: usize) -> ReaderState {
    reader.synchronize(count, None);
    if let Zoom::Scale(scale) = reader.zoom {
        reader.zoom = Zoom::Scale(if scale.is_finite() {
            scale.clamp(MIN_ZOOM, MAX_ZOOM)
        } else {
            1.0
        });
    }
    reader
}

fn save_checkpoint(
    directory: &std::path::Path,
    mut checkpoint: Checkpoint,
) -> Result<(), CoreError> {
    std::fs::create_dir_all(directory)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(directory, std::fs::Permissions::from_mode(0o700))?;
    }
    for (tab, document) in checkpoint.session.tabs.iter_mut().zip(checkpoint.documents) {
        let Some(document) = document else { continue };
        let name = format!(
            "{}.pdf",
            pdf_core::ids::sha256_hex(
                format!(
                    "{}:{}",
                    tab.fingerprint,
                    pdf_core::ids::sha256_hex(&document.bytes)
                )
                .as_bytes()
            )
        );
        let path = directory.join(&name);
        if !path.exists() {
            let bytes = match document.password {
                Some(password) => {
                    let mut parsed = pdf_core::structure::parse(&document.bytes)?;
                    // Keep the source's protection and permissions; never persist a password.
                    pdf_core::security::encrypt(
                        &mut parsed,
                        &password,
                        &password,
                        document.permissions,
                    )?;
                    pdf_core::structure::serialize(&mut parsed)?
                }
                None => document.bytes.as_ref().clone(),
            };
            write_atomically(&path, &bytes)?;
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))?;
            }
        }
        tab.snapshot = Some(name);
    }
    JsonFile::new(directory.join("session.json")).save(&checkpoint.session)?;
    // Only collect after the new manifest has been placed successfully.
    for entry in std::fs::read_dir(directory)?.flatten() {
        let name = entry.file_name().to_string_lossy().into_owned();
        if valid_snapshot_name(&name)
            && !checkpoint
                .session
                .tabs
                .iter()
                .any(|tab| tab.snapshot.as_ref() == Some(&name))
        {
            let _ = std::fs::remove_file(entry.path());
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn recovery_is_atomic_and_protected_and_retains_original_identity() {
        let dir = tempfile::tempdir().unwrap();
        let bytes = pdf_core::testing::protected_pdf(&["recovery"], "secret", "owner", u32::MAX);
        let pdf_core::loader::OpenResult::PasswordRequired(mut locked) =
            pdf_core::loader::open_bytes(bytes, PathBuf::from("original.pdf")).unwrap()
        else {
            panic!("protected fixture")
        };
        let mut original = locked.unlock("secret").unwrap().unwrap();
        let source = original.editor.pdf_data();
        original.editor.rotate_pages(&[0], true).unwrap();
        let edited = original.editor.pdf_data();
        let saved = SavedTab {
            source: original.source_path.clone(),
            fingerprint: original.fingerprint.clone(),
            security: original.security,
            reader: ReaderState::new(1),
            snapshot: None,
            unexported: true,
            page_ids: original.editor.page_ids().to_vec(),
        };
        save_checkpoint(
            dir.path(),
            Checkpoint {
                session: SavedSession {
                    tabs: vec![saved],
                    active: None,
                },
                documents: vec![Some(RecoveryPdf {
                    bytes: edited,
                    password: Some("secret".into()),
                    permissions: original.security.permissions,
                })],
            },
        )
        .unwrap();
        let store = SessionStore::new(dir.path().to_path_buf());
        let saved = store.load().tabs.remove(0);
        let snapshot = std::fs::read(dir.path().join(saved.snapshot.as_ref().unwrap())).unwrap();
        assert!(pdf_core::engine::load(snapshot, None).is_err());
        original.editor.undo().unwrap();
        store.recover(&mut original, &saved).unwrap();
        assert!(original.editor.has_unexported_changes());
        original.editor.undo().unwrap();
        assert_eq!(*original.editor.pdf_data(), *source);
        assert!(
            !std::fs::read_to_string(dir.path().join("session.json"))
                .unwrap()
                .contains("secret")
        );
    }
    #[test]
    fn snapshot_paths_cannot_escape_recovery_directory() {
        assert!(!valid_snapshot_name("../source.pdf"));
        assert!(!valid_snapshot_name("x.pdf"));
        assert!(valid_snapshot_name(&format!("{}.pdf", "a".repeat(64))));
    }
}
