use std::sync::atomic::AtomicBool;

use pdf_core::testing;
use pdf_core::text::{SearchOptions, SearchOutcome, build_text_index, page_infos, search};

fn matches(bytes: &[u8], query: &str, options: SearchOptions) -> SearchOutcome {
    let cancel = AtomicBool::new(false);
    let pages = build_text_index(bytes, &cancel).unwrap();
    search(&pages, query, options, &cancel).unwrap()
}

#[test]
fn case_insensitive_search_finds_every_match_with_boxes() {
    let pdf = testing::text_pdf(&["Alpha beta ALPHA", "nothing here", "alphabet"]);
    let SearchOutcome::Matches(found) = matches(&pdf, "alpha", SearchOptions::default()) else {
        panic!("expected matches");
    };
    assert_eq!(found.iter().map(|m| m.page).collect::<Vec<_>>(), vec![0, 0, 2]);
    assert_eq!(found[1].text, "ALPHA");
    for result in &found {
        let bounds = result.bounds().unwrap();
        assert!(bounds.width() > 10.0 && bounds.height() > 5.0, "{bounds:?}");
        assert!(bounds.y0 > 600.0, "text sits near the top of the page: {bounds:?}");
    }
    assert!(found[0].bounds().unwrap().x1 < found[1].bounds().unwrap().x0, "matches are ordered left to right");
}

#[test]
fn case_sensitive_and_whole_word_options_filter_results() {
    let pdf = testing::text_pdf(&["Alpha alpha alphabet under_score score"]);
    let count = |query: &str, options| match matches(&pdf, query, options) {
        SearchOutcome::Matches(found) => found.len(),
        _ => 0,
    };
    assert_eq!(count("alpha", SearchOptions::default()), 3);
    assert_eq!(count("alpha", SearchOptions { case_sensitive: true, whole_words: false }), 2);
    assert_eq!(count("alpha", SearchOptions { case_sensitive: false, whole_words: true }), 2);
    assert_eq!(count("alpha", SearchOptions { case_sensitive: true, whole_words: true }), 1);
    assert_eq!(count("score", SearchOptions { case_sensitive: false, whole_words: true }), 1, "underscore joins words");
}

#[test]
fn textless_pdf_reports_search_unavailable() {
    let pdf = testing::image_pdf(64, 64);
    assert_eq!(matches(&pdf, "anything", SearchOptions::default()), SearchOutcome::TextUnavailable);
    let text = testing::text_pdf(&["Hello"]);
    assert_eq!(matches(&text, "absent", SearchOptions::default()), SearchOutcome::NoMatches);
    assert_eq!(matches(&text, "   ", SearchOptions::default()), SearchOutcome::NoMatches);
}

#[test]
fn page_infos_report_geometry_and_rotation() {
    let pdf = testing::numbered_pdf(2);
    let infos = page_infos(&pdf).unwrap();
    assert_eq!(infos.len(), 2);
    assert_eq!(infos[0].geometry.display_size(), (612.0, 792.0));
    assert_eq!(infos[0].geometry.rotation, 0);
}
