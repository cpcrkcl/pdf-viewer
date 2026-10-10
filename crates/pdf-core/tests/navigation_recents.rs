use std::collections::HashSet;

use chrono::{Duration, TimeZone, Utc};
use pdf_core::WorkingPageId;
use pdf_core::navigation::{NavigationHistory, NavigationLocation, PageBookmarkStore};
use pdf_core::recents::{PathBookmarkCoder, RecentDocumentsStore};

fn page(n: usize) -> WorkingPageId {
    WorkingPageId::original(&"a".repeat(64), n)
}

fn location(n: usize) -> NavigationLocation {
    NavigationLocation { page_id: page(n) }
}

#[test]
fn history_branches_caps_and_skips_deleted_locations() {
    let mut history = NavigationHistory::new(3);
    history.reset(Some(page(0)));
    history.record(location(1));
    history.record(location(1));
    history.record(location(2));
    assert_eq!(history.entries().len(), 3);
    history.record(location(3));
    assert_eq!(history.entries().len(), 3, "history is capped");
    assert_eq!(history.entries()[0], location(1));

    let all: HashSet<_> = (0..5).map(page).collect();
    assert_eq!(history.go_back(&all), Some(location(2)));
    history.record(location(4));
    assert!(!history.can_go_forward(&all), "recording discards forward entries");

    let without_two: HashSet<_> = [1, 3, 4].into_iter().map(page).collect();
    assert_eq!(history.go_back(&without_two), Some(location(1)), "deleted pages are skipped");
    assert_eq!(history.go_forward(&without_two), Some(location(4)));
    assert!(!history.can_go_forward(&without_two));
}

#[test]
fn bookmarks_persist_rename_remove_and_round_trip_json() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("bookmarks.json");
    let fingerprint = "b".repeat(64);
    let created = Utc.with_ymd_and_hms(2026, 1, 1, 0, 0, 0).unwrap();
    let mut store = PageBookmarkStore::new(path.clone());
    let first = store.add_at(&fingerprint, page(0), "   ", created);
    assert_eq!(first.label, "Bookmark");
    let second = store.add_at(&fingerprint, page(1), &"x".repeat(500), created + Duration::seconds(1));
    assert_eq!(second.label.chars().count(), 120);
    store.rename(first.id, "Intro");

    let reloaded = PageBookmarkStore::new(path.clone());
    let labels: Vec<_> = reloaded.bookmarks_for(&fingerprint).into_iter().map(|b| b.label).collect();
    assert_eq!(labels[0], "Intro");

    let exported = store.export_json().unwrap();
    store.remove(second.id);
    assert_eq!(store.all().len(), 1);
    store.import_json(&exported).unwrap();
    store.import_json(&exported).unwrap();
    assert_eq!(store.all().len(), 2, "imports merge without duplicates");
    assert!(store.import_json(br#"{"version":2,"bookmarks":[]}"#).is_err());
}

#[test]
fn recents_keep_ten_unique_most_recent_first_and_round_trip() {
    let dir = tempfile::tempdir().unwrap();
    let store_path = dir.path().join("recents.json");
    let mut store = RecentDocumentsStore::new(store_path.clone(), Box::new(PathBookmarkCoder), 10);
    let base = Utc.with_ymd_and_hms(2026, 1, 1, 0, 0, 0).unwrap();
    for n in 0..12 {
        let file = dir.path().join(format!("{n}.pdf"));
        std::fs::write(&file, b"%PDF").unwrap();
        store.record_at(&file, base + Duration::minutes(n)).unwrap();
    }
    let again = dir.path().join("5.pdf");
    store.record_at(&again, base + Duration::hours(1)).unwrap();
    let names: Vec<_> = store.documents().iter().map(|d| d.display_name.clone()).collect();
    assert_eq!(names.len(), 10);
    assert_eq!(names[0], "5.pdf");
    assert_eq!(names.iter().filter(|name| *name == "5.pdf").count(), 1);
    assert_eq!(store.resolve(&store.documents()[0]).unwrap(), again);

    let exported = store.export_json().unwrap();
    let mut other = RecentDocumentsStore::new(dir.path().join("other.json"), Box::new(PathBookmarkCoder), 10);
    other.import_json(&exported).unwrap();
    other.import_json(&exported).unwrap();
    assert_eq!(other.documents(), store.documents());

    let reloaded = RecentDocumentsStore::new(store_path, Box::new(PathBookmarkCoder), 3);
    assert_eq!(reloaded.documents().len(), 3, "oversized persisted history is trimmed");
}
