use std::collections::HashSet;

use pdfium_render::prelude::*;

use crate::ids::WorkingPageId;

pub const MAXIMUM_DEPTH: usize = 128;
pub const MAXIMUM_NODE_COUNT: usize = 20_000;
pub const MAXIMUM_LABEL_LENGTH: usize = 512;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OutlineNode {
    /// Dotted child-index path, stable for a given outline.
    pub id: String,
    pub title: String,
    pub page_id: Option<WorkingPageId>,
    pub children: Vec<OutlineNode>,
}

impl OutlineNode {
    pub fn is_navigable(&self) -> bool {
        self.page_id.is_some()
    }
}

/// Builds a bounded outline tree. Cycles, excessive depth and excessive node
/// counts in hostile documents are cut off rather than followed.
pub fn build_outline(document: &PdfDocument, page_ids: &[WorkingPageId]) -> Vec<OutlineNode> {
    let Some(root) = document.bookmarks().root() else {
        return Vec::new();
    };
    let mut state = State {
        page_ids,
        visited: HashSet::new(),
        loaded: 0,
    };
    let mut nodes = Vec::new();
    let mut sibling = Some(root);
    let mut index = 0;
    while let Some(bookmark) = sibling {
        if state.loaded >= MAXIMUM_NODE_COUNT {
            break;
        }
        let next = bookmark.next_sibling();
        if let Some(node) = make_node(&bookmark, index.to_string(), 0, &mut state) {
            nodes.push(node);
        } else if !state.visited.is_empty() && state.loaded >= MAXIMUM_NODE_COUNT {
            break;
        }
        sibling = next;
        index += 1;
        if index > MAXIMUM_NODE_COUNT {
            break;
        }
    }
    nodes
}

struct State<'a> {
    page_ids: &'a [WorkingPageId],
    visited: HashSet<String>,
    loaded: usize,
}

fn make_node(bookmark: &PdfBookmark, path: String, depth: usize, state: &mut State) -> Option<OutlineNode> {
    if depth >= MAXIMUM_DEPTH || state.loaded >= MAXIMUM_NODE_COUNT {
        return None;
    }
    // PDFium bookmark handles are stable per dictionary; the title+path pair
    // is a sufficient cycle guard together with depth and count limits.
    let identity = format!("{:?}|{path}", bookmark.title());
    if !state.visited.insert(identity) {
        return None;
    }
    state.loaded += 1;

    let title = bookmark
        .title()
        .map(|title| title.trim().to_owned())
        .filter(|title| !title.is_empty())
        .unwrap_or_else(|| "Untitled Section".to_owned());
    let title: String = title.chars().take(MAXIMUM_LABEL_LENGTH).collect();

    let page_index = bookmark
        .destination()
        .and_then(|destination| destination.page_index().ok())
        .or_else(|| {
            bookmark.action().and_then(|action| {
                action
                    .as_local_destination_action()
                    .and_then(|local| local.destination().ok())
                    .and_then(|destination| destination.page_index().ok())
            })
        });
    let page_id = page_index.and_then(|index| state.page_ids.get(index as usize).cloned());

    let mut children = Vec::new();
    let mut child = bookmark.first_child();
    let mut child_index = 0;
    while let Some(current) = child {
        if state.loaded >= MAXIMUM_NODE_COUNT {
            break;
        }
        let next = current.next_sibling();
        if let Some(node) = make_node(&current, format!("{path}.{child_index}"), depth + 1, state) {
            children.push(node);
        }
        child = next;
        child_index += 1;
        if child_index > MAXIMUM_NODE_COUNT {
            break;
        }
    }

    Some(OutlineNode {
        id: path,
        title,
        page_id,
        children,
    })
}
