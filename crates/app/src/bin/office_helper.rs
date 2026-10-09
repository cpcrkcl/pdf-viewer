//! `PDFViewerOfficeHelper <soffice> <document>`: converts one Office document
//! with a user-installed LibreOffice and writes the PDF to standard output.
//! Errors are short generic messages on standard error with exit status 1.

use std::io::Write;
use std::path::PathBuf;

fn main() {
    let arguments: Vec<PathBuf> = std::env::args_os().skip(1).map(PathBuf::from).collect();
    let result = match arguments.as_slice() {
        [executable, input] => pdf_core::office::convert(executable, input).map_err(|error| error.to_string()),
        _ => Err("Usage: PDFViewerOfficeHelper <soffice> <document>".to_owned()),
    };
    match result {
        Ok(pdf) => {
            let mut stdout = std::io::stdout().lock();
            if stdout.write_all(&pdf).and_then(|()| stdout.flush()).is_err() {
                std::process::exit(1);
            }
        }
        Err(message) => {
            eprintln!("{message}");
            std::process::exit(1);
        }
    }
}
