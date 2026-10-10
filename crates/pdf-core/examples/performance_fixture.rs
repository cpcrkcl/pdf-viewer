//! Reproducible fixture for manual scrolling, recovery and batch checks.
fn main() {
    let mut args = std::env::args_os().skip(1);
    let path = std::path::PathBuf::from(
        args.next()
            .expect("usage: performance_fixture OUTPUT.pdf [PAGE_COUNT]"),
    );
    let count: usize = args
        .next()
        .and_then(|value| value.to_str().and_then(|value| value.parse().ok()))
        .unwrap_or(2000);
    assert!((1..=10000).contains(&count));
    let bytes = pdf_core::testing::numbered_pdf(count);
    use std::io::Write;
    std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(path)
        .unwrap()
        .write_all(&bytes)
        .unwrap();
}
