//! Native macOS integration: the menu bar, Finder open-file events, the
//! quit request from the Dock or logout, printing through PDFKit, and the
//! pasteboard.
//!
//! AppKit callbacks only queue events; the app drains them each frame.

use std::cell::RefCell;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Mutex, OnceLock};

use objc2::rc::Retained;
use objc2::runtime::{AnyClass, AnyObject, Imp, Sel};
use objc2::{AnyThread, MainThreadMarker, MainThreadOnly, define_class, msg_send, sel};
use objc2_app_kit::{
    NSApplication, NSApplicationTerminateReply, NSControlStateValueOff,
    NSControlStateValueOn, NSEventModifierFlags, NSMenu, NSMenuItem, NSPasteboard,
    NSPasteboardTypeString, NSPrintInfo,
};
use objc2_foundation::{NSArray, NSData, NSObject, NSString, NSUInteger, NSURL};
use objc2_pdf_kit::{PDFDocument, PDFPrintScalingMode};

use crate::commands::{Command, CommandState};
use crate::reader_state::{DisplayMode, ReaderTheme};

pub enum NativeEvent {
    Command(Command),
    Open(PathBuf),
}

static QUEUE: Mutex<Vec<NativeEvent>> = Mutex::new(Vec::new());
static CONTEXT: OnceLock<egui::Context> = OnceLock::new();
/// Set by the app each frame: nothing unexported and no job running.
static CAN_TERMINATE: AtomicBool = AtomicBool::new(true);

pub fn set_can_terminate(can_terminate: bool) {
    CAN_TERMINATE.store(can_terminate, Ordering::Relaxed);
}

fn post(event: NativeEvent) {
    // eframe skips frames for minimized or hidden windows, so queued events
    // would wait until the user restored the window.
    show_window();
    QUEUE.lock().unwrap().push(event);
    if let Some(ctx) = CONTEXT.get() {
        ctx.request_repaint();
    }
}

fn show_window() {
    let Some(mtm) = MainThreadMarker::new() else { return };
    let app = NSApplication::sharedApplication(mtm);
    #[allow(deprecated)]
    app.activateIgnoringOtherApps(true);
    if let Some(window) = app.windows().firstObject() {
        if window.isMiniaturized() {
            window.deminiaturize(None);
        }
        window.makeKeyAndOrderFront(None);
    }
}

pub fn drain() -> Vec<NativeEvent> {
    std::mem::take(&mut *QUEUE.lock().unwrap())
}

/// Lets queued events wake the UI.
pub fn attach(ctx: &egui::Context) {
    let _ = CONTEXT.set(ctx.clone());
}

// MARK: Application delegate

/// Finder opens (`application:openURLs:`) and quit requests from the Dock,
/// app switcher or logout (`applicationShouldTerminate:`).
///
/// Winit 0.30 owns NSApplication's delegate and panics if it is replaced, so
/// these methods are added to winit's own delegate class instead. Call after
/// the event loop is built and before it runs, so launch-time opens arrive.
pub fn extend_app_delegate() -> bool {
    let Some(mtm) = MainThreadMarker::new() else { return false };
    let app = NSApplication::sharedApplication(mtm);
    let Some(delegate) = app.delegate() else { return false };
    let object: &AnyObject = (*delegate).as_ref();
    let class = object.class() as *const AnyClass as *mut AnyClass;
    // Type encodings: void(id, SEL, id, id) and NSUInteger(id, SEL, id).
    let added = unsafe {
        let open = std::mem::transmute::<OpenUrls, Imp>(open_urls);
        let terminate = std::mem::transmute::<ShouldTerminate, Imp>(should_terminate);
        let open_added = objc2::ffi::class_addMethod(class, sel!(application:openURLs:), open, c"v@:@@".as_ptr());
        let terminate_added = objc2::ffi::class_addMethod(class, sel!(applicationShouldTerminate:), terminate, c"Q@:@".as_ptr());
        open_added.as_bool() && terminate_added.as_bool()
    };
    // AppKit caches which optional methods a delegate implements when it is
    // set, so set the same delegate again.
    app.setDelegate(Some(&delegate));
    added
}

type OpenUrls = unsafe extern "C-unwind" fn(&AnyObject, Sel, &AnyObject, &NSArray<NSURL>);
type ShouldTerminate = unsafe extern "C-unwind" fn(&AnyObject, Sel, &AnyObject) -> NSUInteger;

unsafe extern "C-unwind" fn open_urls(_this: &AnyObject, _cmd: Sel, _application: &AnyObject, urls: &NSArray<NSURL>) {
    for url in urls.iter() {
        if let Some(path) = url.path() {
            post(NativeEvent::Open(PathBuf::from(path.to_string())));
        }
    }
}

/// Quitting from the Dock, logout or shutdown proceeds at once when nothing
/// would be lost (winit then ends the loop and eframe saves its state).
/// Otherwise it is cancelled and the app asks about unexported changes, as
/// when closing the window.
unsafe extern "C-unwind" fn should_terminate(_this: &AnyObject, _cmd: Sel, _application: &AnyObject) -> NSUInteger {
    if CAN_TERMINATE.load(Ordering::Relaxed) {
        return NSApplicationTerminateReply::TerminateNow.0;
    }
    post(NativeEvent::Command(Command::Quit));
    NSApplicationTerminateReply::TerminateCancel.0
}

// MARK: Menu bar

define_class!(
    #[unsafe(super(NSObject))]
    #[thread_kind = MainThreadOnly]
    #[name = "PDFViewerMenuTarget"]
    struct MenuTarget;

    impl MenuTarget {
        #[unsafe(method(perform:))]
        fn perform(&self, sender: &NSMenuItem) {
            let tag = sender.tag();
            let command = MENU.with(|menu| menu.borrow().as_ref().and_then(|menu| menu.commands.get(tag as usize).copied()));
            if let Some(command) = command {
                post(NativeEvent::Command(command));
            }
        }
    }
);

impl MenuTarget {
    fn new(mtm: MainThreadMarker) -> Retained<Self> {
        let this = Self::alloc(mtm).set_ivars(());
        unsafe { msg_send![super(this), init] }
    }
}

struct Menu {
    target: Retained<MenuTarget>,
    /// Indexed by item tag.
    commands: Vec<Command>,
    items: Vec<(Retained<NSMenuItem>, CommandState)>,
    recents: Retained<NSMenu>,
    recent_titles: Vec<String>,
}

thread_local! {
    static MENU: RefCell<Option<Menu>> = const { RefCell::new(None) };
}

enum Entry {
    Item(&'static str, Command, &'static str, NSEventModifierFlags),
    /// A standard AppKit action sent along the responder chain.
    Standard(&'static str, Sel, &'static str, NSEventModifierFlags),
    Submenu(&'static str, Vec<Entry>),
    Recents,
    Separator,
}

const CMD: NSEventModifierFlags = NSEventModifierFlags::Command;

fn item(title: &'static str, command: Command) -> Entry {
    Entry::Item(title, command, "", CMD)
}

fn key(title: &'static str, command: Command, key: &'static str) -> Entry {
    Entry::Item(title, command, key, CMD)
}

fn key_with(
    title: &'static str,
    command: Command,
    key: &'static str,
    extra: NSEventModifierFlags,
) -> Entry {
    Entry::Item(title, command, key, CMD | extra)
}

fn layout() -> Vec<(&'static str, Vec<Entry>)> {
    use Command::*;
    use Entry::Separator;
    let shift = NSEventModifierFlags::Shift;
    let option = NSEventModifierFlags::Option;
    let mut view = vec![
        key("Commands…", Palette, "k"),
        key_with("Split Reading View", ToggleSplit, "\\", shift),
        key_with("Toggle Sidebar", ToggleSidebar, "s", option),
        Separator,
    ];
    view.extend(DisplayMode::ALL.map(|mode| item(mode.title(), Display(mode))));
    view.push(Separator);
    view.extend(ReaderTheme::ALL.map(|theme| item(theme.title(), Theme(theme))));
    view.extend([
        Separator,
        key("Zoom In", ZoomIn, "+"),
        key("Zoom Out", ZoomOut, "-"),
        key("Zoom to Fit", ZoomToFit, "0"),
        item("Actual Size", ActualSize),
        Separator,
        key_with("Annotation Tools", ToggleAnnotate, "a", shift),
        item("Redaction Tool", ToggleRedact),
        item("Form Panel", ToggleForms),
        Separator,
        item("Page Labels…", PageLabels),
    ]);
    vec![
        (
            "PDFViewer",
            vec![
                Entry::Standard(
                    "About PDFViewer",
                    sel!(orderFrontStandardAboutPanel:),
                    "",
                    CMD,
                ),
                Separator,
                Entry::Standard("Hide PDFViewer", sel!(hide:), "h", CMD),
                Entry::Standard(
                    "Hide Others",
                    sel!(hideOtherApplications:),
                    "h",
                    CMD | option,
                ),
                Entry::Standard("Show All", sel!(unhideAllApplications:), "", CMD),
                Separator,
                key("Quit PDFViewer", Quit, "q"),
            ],
        ),
        (
            "File",
            vec![
                key("Open…", Open, "o"),
                Entry::Recents,
                Separator,
                key_with("Export PDF…", Export, "s", shift),
                item("Extract Selected Pages…", ExtractPages),
                item("Convert…", Convert),
                Separator,
                key("Print…", Print, "p"),
                Separator,
                Entry::Submenu(
                    "Library Data",
                    vec![
                        item("Export Bookmarks as JSON…", ExportBookmarks),
                        item("Import Bookmarks from JSON…", ImportBookmarks),
                        Separator,
                        item("Export Recent Documents as JSON…", ExportRecents),
                        item("Import Recent Documents from JSON…", ImportRecents),
                    ],
                ),
                Separator,
                key("Close Tab", CloseTab, "w"),
            ],
        ),
        (
            "Edit",
            vec![
                key("Undo", Undo, "z"),
                key_with("Redo", Redo, "z", shift),
                Separator,
                key("Cut", Cut, "x"),
                key("Copy", Copy, "c"),
                key("Paste", Paste, "v"),
                key("Select All", SelectAll, "a"),
                Separator,
                key("Find…", Find, "f"),
                key("Find Next", FindNext, "g"),
                key_with("Find Previous", FindPrevious, "g", shift),
            ],
        ),
        ("View", view),
        (
            "Go",
            vec![
                item("Previous Page", PreviousPage),
                item("Next Page", NextPage),
                item("First Page", FirstPage),
                item("Last Page", LastPage),
                Separator,
                key("Back", Back, "["),
                key("Forward", Forward, "]"),
                Separator,
                key("Add Bookmark", AddBookmark, "d"),
                Separator,
                item("Next Tab", NextTab),
            ],
        ),
        (
            "Pages",
            vec![
                key("Rotate Right", RotateRight, "r"),
                key_with("Rotate Left", RotateLeft, "r", shift),
                Separator,
                item("Move Up", MoveUp),
                item("Move Down", MoveDown),
                item("Move to Beginning", MoveToBeginning),
                item("Move to End", MoveToEnd),
                Separator,
                item("Insert Pages from PDF…", InsertPages),
                item("Delete Selected Pages…", DeletePages),
                Separator,
                item("OCR & Scan Enhancement…", Ocr),
            ],
        ),
        (
            "Window",
            vec![
                Entry::Standard("Minimize", sel!(performMiniaturize:), "m", CMD),
                Entry::Standard("Zoom", sel!(performZoom:), "", CMD),
                Separator,
                Entry::Standard("Bring All to Front", sel!(arrangeInFront:), "", CMD),
            ],
        ),
    ]
}

fn new_item(
    mtm: MainThreadMarker,
    title: &str,
    action: Option<Sel>,
    key: &str,
    modifiers: NSEventModifierFlags,
) -> Retained<NSMenuItem> {
    let item = unsafe {
        NSMenuItem::initWithTitle_action_keyEquivalent(
            NSMenuItem::alloc(mtm),
            &NSString::from_str(title),
            action,
            &NSString::from_str(key),
        )
    };
    item.setKeyEquivalentModifierMask(modifiers);
    item
}

fn new_menu(mtm: MainThreadMarker, title: &str) -> Retained<NSMenu> {
    let menu = NSMenu::initWithTitle(NSMenu::alloc(mtm), &NSString::from_str(title));
    // Enabled states come from the app, not from responder validation.
    menu.setAutoenablesItems(false);
    menu
}

fn build(mtm: MainThreadMarker, menu: &mut Menu, parent: &NSMenu, entries: Vec<Entry>) {
    for entry in entries {
        match entry {
            Entry::Separator => parent.addItem(&NSMenuItem::separatorItem(mtm)),
            Entry::Item(title, command, key, modifiers) => {
                let item = new_item(mtm, title, Some(sel!(perform:)), key, modifiers);
                unsafe { item.setTarget(Some(&menu.target)) };
                item.setTag(menu.commands.len() as isize);
                menu.commands.push(command);
                parent.addItem(&item);
                menu.items.push((
                    item,
                    CommandState {
                        enabled: true,
                        checked: false,
                    },
                ));
            }
            Entry::Standard(title, action, key, modifiers) => {
                parent.addItem(&new_item(mtm, title, Some(action), key, modifiers))
            }
            Entry::Submenu(title, children) => {
                let submenu = new_menu(mtm, title);
                build(mtm, menu, &submenu, children);
                let item = new_item(mtm, title, None, "", CMD);
                item.setSubmenu(Some(&submenu));
                parent.addItem(&item);
            }
            Entry::Recents => {
                let item = new_item(mtm, "Open Recent", None, "", CMD);
                item.setSubmenu(Some(&menu.recents));
                parent.addItem(&item);
            }
        }
    }
}

/// Replaces winit's minimal menu with the full PDFViewer menu bar.
pub fn install_menu() -> bool {
    let Some(mtm) = MainThreadMarker::new() else {
        return false;
    };
    let target = MenuTarget::new(mtm);
    let mut menu = Menu {
        target,
        commands: Vec::new(),
        items: Vec::new(),
        recents: new_menu(mtm, "Open Recent"),
        recent_titles: vec!["\u{0}".into()],
    };
    let bar = new_menu(mtm, "");
    let app = NSApplication::sharedApplication(mtm);
    for (title, entries) in layout() {
        let submenu = new_menu(mtm, title);
        build(mtm, &mut menu, &submenu, entries);
        let item = new_item(mtm, title, None, "", CMD);
        item.setSubmenu(Some(&submenu));
        bar.addItem(&item);
        if title == "Window" {
            app.setWindowsMenu(Some(&submenu));
        }
    }
    app.setMainMenu(Some(&bar));
    MENU.with(|slot| *slot.borrow_mut() = Some(menu));
    true
}

/// Applies enabled and checked states, and rebuilds Open Recent when the
/// list changed. Cheap enough to call every frame.
pub fn update_menu(state: impl Fn(Command) -> CommandState, recent_titles: &[String]) {
    let Some(mtm) = MainThreadMarker::new() else {
        return;
    };
    MENU.with(|slot| {
        let mut slot = slot.borrow_mut();
        let Some(menu) = slot.as_mut() else { return };
        for ((item, current), command) in menu.items.iter_mut().zip(menu.commands.iter()) {
            let next = state(*command);
            if next != *current {
                item.setEnabled(next.enabled);
                item.setState(if next.checked {
                    NSControlStateValueOn
                } else {
                    NSControlStateValueOff
                });
                *current = next;
            }
        }
        if menu.recent_titles != recent_titles {
            menu.recent_titles = recent_titles.to_vec();
            menu.recents.removeAllItems();
            if recent_titles.is_empty() {
                let empty = new_item(mtm, "No Recent Documents", None, "", CMD);
                empty.setEnabled(false);
                menu.recents.addItem(&empty);
            }
            // Recent entries reuse tags past the fixed commands.
            menu.commands.truncate(menu.items.len());
            for (index, title) in recent_titles.iter().enumerate() {
                let item = new_item(mtm, title, Some(sel!(perform:)), "", CMD);
                unsafe { item.setTarget(Some(&menu.target)) };
                item.setTag(menu.commands.len() as isize);
                menu.commands.push(Command::OpenRecent(index));
                menu.recents.addItem(&item);
            }
            menu.recents.addItem(&NSMenuItem::separatorItem(mtm));
            let clear = new_item(mtm, "Clear Menu", Some(sel!(perform:)), "", CMD);
            unsafe { clear.setTarget(Some(&menu.target)) };
            clear.setTag(menu.commands.len() as isize);
            clear.setEnabled(!recent_titles.is_empty());
            menu.commands.push(Command::ClearRecents);
            menu.recents.addItem(&clear);
        }
    });
}

// MARK: Pasteboard and printing

pub fn pasteboard_text() -> Option<String> {
    let pasteboard = NSPasteboard::generalPasteboard();
    pasteboard
        .stringForType(unsafe { NSPasteboardTypeString })
        .map(|text| text.to_string())
}

thread_local! {
    /// Kept alive while its print sheet is open.
    static PRINTING: RefCell<Option<Retained<PDFDocument>>> = const { RefCell::new(None) };
}

/// Shows the print sheet for `pdf` (the in-memory working copy) on the main
/// window. Nothing is written to disk.
pub fn print(pdf: &[u8], title: &str) -> Result<(), String> {
    let mtm = MainThreadMarker::new().ok_or("Printing must start on the main thread.")?;
    let app = NSApplication::sharedApplication(mtm);
    let window = app.mainWindow().or_else(|| app.keyWindow());
    // One sheet at a time: the print panel is already showing.
    if window.as_ref().is_some_and(|window| window.attachedSheet().is_some()) {
        return Ok(());
    }
    let document =
        unsafe { PDFDocument::initWithData(PDFDocument::alloc(), &NSData::with_bytes(pdf)) }
            .ok_or("PDFViewer could not prepare this PDF for printing.")?;
    let info = NSPrintInfo::sharedPrintInfo();
    let operation = unsafe {
        document.printOperationForPrintInfo_scalingMode_autoRotate(
            Some(&info),
            PDFPrintScalingMode::PageScaleDownToFit,
            true,
            mtm,
        )
    }
    .ok_or("PDFViewer could not prepare this PDF for printing.")?;
    operation.setJobTitle(Some(&NSString::from_str(title)));
    operation.setShowsPrintPanel(true);
    operation.setShowsProgressPanel(true);
    PRINTING.with(|slot| *slot.borrow_mut() = Some(document));
    match window {
        Some(window) => unsafe {
            operation.runOperationModalForWindow_delegate_didRunSelector_contextInfo(
                &window,
                None::<&AnyObject>,
                None,
                std::ptr::null_mut(),
            )
        },
        None => {
            operation.runOperation();
        }
    }
    Ok(())
}
