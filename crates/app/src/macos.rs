//! macOS integration: security-scoped bookmarks for recent documents.

use std::path::{Path, PathBuf};
use std::sync::Mutex;

use objc2::rc::Retained;
use objc2::runtime::Bool;
use objc2_foundation::{NSData, NSString, NSURL, NSURLBookmarkCreationOptions, NSURLBookmarkResolutionOptions};
use pdf_core::recents::BookmarkCoder;
use pdf_core::{CoreError, CoreResult};

/// URLs whose security scope was entered when resolved from a recent
/// document. Access lasts for the rest of the process, mirroring a window
/// that stays open; the sandbox revokes it at exit.
static ACCESSED: Mutex<Vec<Retained<NSURL>>> = Mutex::new(Vec::new());

pub struct SecurityScopedBookmarkCoder;

impl BookmarkCoder for SecurityScopedBookmarkCoder {
    fn bookmark(&self, path: &Path) -> CoreResult<Vec<u8>> {
        let url = NSURL::fileURLWithPath(&NSString::from_str(&path.to_string_lossy()));
        // Security scope requires the sandbox's bookmark entitlement; outside
        // the sandbox a plain bookmark still survives renames and moves.
        let data = url
            .bookmarkDataWithOptions_includingResourceValuesForKeys_relativeToURL_error(
                NSURLBookmarkCreationOptions::WithSecurityScope,
                None,
                None,
            )
            .or_else(|_| {
                url.bookmarkDataWithOptions_includingResourceValuesForKeys_relativeToURL_error(
                    NSURLBookmarkCreationOptions::empty(),
                    None,
                    None,
                )
            })
            .map_err(|_| CoreError::FileUnavailable)?;
        Ok(data.to_vec())
    }

    fn resolve(&self, bookmark: &[u8]) -> CoreResult<PathBuf> {
        let data = NSData::with_bytes(bookmark);
        let mut stale = Bool::NO;
        let mut resolve = |options| unsafe {
            NSURL::URLByResolvingBookmarkData_options_relativeToURL_bookmarkDataIsStale_error(
                &data,
                options,
                None,
                &mut stale,
            )
        };
        let url = resolve(NSURLBookmarkResolutionOptions::WithSecurityScope | NSURLBookmarkResolutionOptions::WithoutUI)
            .or_else(|_| resolve(NSURLBookmarkResolutionOptions::WithoutUI))
            .map_err(|_| CoreError::FileUnavailable)?;
        if unsafe { url.startAccessingSecurityScopedResource() } {
            ACCESSED.lock().unwrap().push(url.clone());
        }
        let path = url.path().ok_or(CoreError::FileUnavailable)?;
        Ok(PathBuf::from(path.to_string()))
    }
}
