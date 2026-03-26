//! Lens - recursive stacked buffer system for drilling into code
//!
//! Each buffer (including the root) can have multiple lenses open at different
//! line positions. Each lens is itself a buffer that can contain child lenses.
//! This forms a navigation tree. The "focus path" tracks which lens is active
//! at each depth level.
//!
//! Example tree:
//!   root buffer (main.rs)
//!     ├─ lens at line 10 → lib.rs
//!     │    └─ lens at line 5 → utils.rs   ← currently focused
//!     └─ lens at line 25 → config.rs
//!
//! Alt+Up walks up the focus path, Alt+Down walks back down.

use crate::editor::CursorPosition;
use crate::editor::EditorBuffer;
use crate::file::FileBuffer;

/// Initial padding above/below cursor when a lens opens
const INITIAL_PADDING: usize = 2;

/// A single lens: a focused view into a buffer, inserted at a line in the parent.
/// Can itself contain child lenses at various positions within its own buffer.
#[derive(Clone, Debug)]
pub struct LensLayer {
    /// The buffer being viewed in this lens
    pub buffer: EditorBuffer,
    /// Cursor position within this lens buffer
    pub cursor: CursorPosition,
    /// First visible line (inclusive) — grows when cursor moves past edge
    pub window_top: usize,
    /// Last visible line (inclusive) — grows when cursor moves past edge
    pub window_bottom: usize,
    /// The line in the PARENT buffer where this lens was inserted
    pub parent_line: usize,
    /// File path for display in separator
    pub file_name: String,
    /// Whether this layer has unsaved changes
    pub dirty: bool,
    /// Child lenses open within this buffer, sorted by parent_line
    pub children: Vec<LensLayer>,
    /// Index of the currently focused child (if any)
    pub focused_child: Option<usize>,
}

impl LensLayer {
    /// Create a new lens layer from a file
    pub fn from_file(file_buffer: FileBuffer, parent_line: usize) -> Self {
        Self::from_file_at(file_buffer, parent_line, 0)
    }

    /// Create a new lens layer opening at a specific line in the child file
    pub fn from_file_at(file_buffer: FileBuffer, parent_line: usize, start_line: usize) -> Self {
        let file_name = file_buffer
            .path
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("untitled")
            .to_string();

        let buf_len = file_buffer.lines.len();
        let cursor_line = start_line.min(buf_len.saturating_sub(1));
        let window_top = cursor_line.saturating_sub(INITIAL_PADDING);
        let window_bottom = (cursor_line + INITIAL_PADDING).min(buf_len.saturating_sub(1));

        LensLayer {
            buffer: EditorBuffer::from(file_buffer),
            cursor: CursorPosition::new(cursor_line, 0),
            window_top,
            window_bottom,
            parent_line,
            file_name,
            dirty: false,
            children: Vec::new(),
            focused_child: None,
        }
    }

    /// Expand the visible window if cursor moved past an edge
    pub fn expand_to_cursor(&mut self) {
        if self.cursor.line < self.window_top {
            self.window_top = self.cursor.line;
        }
        if self.cursor.line > self.window_bottom {
            self.window_bottom = self.cursor.line;
        }
        let max_line = self.buffer.len().saturating_sub(1);
        self.window_bottom = self.window_bottom.min(max_line);
    }

    /// Get the range of visible lines: [window_top, window_bottom+1) exclusive end
    pub fn visible_range(&self) -> (usize, usize) {
        (self.window_top, self.window_bottom + 1)
    }

    /// Total visible height (content + 2 separators)
    pub fn visible_height(&self) -> usize {
        (self.window_bottom - self.window_top + 1) + 2
    }

    /// Open a child lens at the current cursor position
    pub fn open_child(&mut self, file_buffer: FileBuffer) {
        let child = LensLayer::from_file(file_buffer, self.cursor.line);
        // Insert sorted by parent_line
        let pos = self
            .children
            .iter()
            .position(|c| c.parent_line > child.parent_line)
            .unwrap_or(self.children.len());
        self.children.insert(pos, child);
        self.focused_child = Some(pos);
    }

    /// Drill into the focused child (returns false if no focused child)
    pub fn has_focused_child(&self) -> bool {
        self.focused_child.is_some()
    }

    /// Get the focused child
    pub fn focused_child_ref(&self) -> Option<&LensLayer> {
        self.focused_child.and_then(|i| self.children.get(i))
    }

    /// Get mutable focused child
    pub fn focused_child_mut(&mut self) -> Option<&mut LensLayer> {
        self.focused_child.and_then(|i| self.children.get_mut(i))
    }

    /// Unfocus the child (step back up to this layer)
    pub fn unfocus_child(&mut self) {
        self.focused_child = None;
    }

    /// Get the deepest focused descendant (the leaf of the focus path)
    pub fn active_leaf(&self) -> &LensLayer {
        if let Some(child) = self.focused_child_ref() {
            child.active_leaf()
        } else {
            self
        }
    }

    /// Get mutable reference to the deepest focused descendant
    pub fn active_leaf_mut(&mut self) -> &mut LensLayer {
        if self.focused_child.is_some() {
            self.focused_child_mut().unwrap().active_leaf_mut()
        } else {
            self
        }
    }

    /// Get the focus depth from this layer down
    pub fn focus_depth(&self) -> usize {
        if let Some(child) = self.focused_child_ref() {
            1 + child.focus_depth()
        } else {
            0
        }
    }

    /// Unfocus the deepest child in the focus chain (pop one level).
    /// Returns true if something was unfocused, false if already at leaf.
    pub fn unfocus_deepest(&mut self) -> bool {
        if let Some(idx) = self.focused_child {
            let child = &mut self.children[idx];
            if child.focused_child.is_some() {
                // Recurse deeper
                child.unfocus_deepest()
            } else {
                // This child is the leaf — unfocus it
                self.focused_child = None;
                true
            }
        } else {
            false
        }
    }

    /// Re-focus the child at the current cursor position (if one exists there).
    /// Used for Alt+Down to drill back into a previously opened lens.
    pub fn refocus_child_at_cursor(&mut self) -> bool {
        if let Some(idx) = self.children.iter().position(|c| c.parent_line == self.cursor.line) {
            self.focused_child = Some(idx);
            true
        } else {
            false
        }
    }
}

/// The lens tree rooted at the main buffer.
/// The main buffer itself is not a LensLayer — it's the Editor.
/// This struct tracks the top-level lenses and which one is focused.
#[derive(Debug)]
pub struct LensStack {
    /// Top-level lenses (children of the root/main buffer), sorted by parent_line
    pub roots: Vec<LensLayer>,
    /// Index of the currently focused root lens (if any)
    pub focused_root: Option<usize>,
}

impl LensStack {
    pub fn new() -> Self {
        LensStack {
            roots: Vec::new(),
            focused_root: None,
        }
    }

    /// Open a new lens at the given parent line in the main buffer
    pub fn open_at_root(&mut self, file_buffer: FileBuffer, parent_line: usize) {
        let layer = LensLayer::from_file(file_buffer, parent_line);
        let pos = self
            .roots
            .iter()
            .position(|c| c.parent_line > layer.parent_line)
            .unwrap_or(self.roots.len());
        self.roots.insert(pos, layer);
        self.focused_root = Some(pos);
    }

    /// Is there any focused lens?
    pub fn is_active(&self) -> bool {
        self.focused_root.is_some()
    }

    /// Get the deepest focused lens layer (the leaf of the focus path)
    pub fn active_leaf(&self) -> Option<&LensLayer> {
        self.focused_root.map(|i| self.roots[i].active_leaf())
    }

    /// Get mutable reference to the deepest focused lens
    pub fn active_leaf_mut(&mut self) -> Option<&mut LensLayer> {
        self.focused_root.map(|i| self.roots[i].active_leaf_mut())
    }

    /// Total focus depth (0 = no lens, 1 = root lens, 2 = child of root, etc.)
    pub fn depth(&self) -> usize {
        match self.focused_root {
            Some(i) => 1 + self.roots[i].focus_depth(),
            None => 0,
        }
    }

    /// Navigate up one level. Returns true if we moved up.
    pub fn focus_up(&mut self) -> bool {
        if let Some(idx) = self.focused_root {
            let root = &mut self.roots[idx];
            if root.focused_child.is_some() {
                // Unfocus the deepest child in this root's chain
                root.unfocus_deepest()
            } else {
                // Already at root lens — unfocus it entirely
                self.focused_root = None;
                true
            }
        } else {
            false
        }
    }

    /// Navigate down one level at cursor position. Returns true if drilled down.
    /// First checks if the active leaf has a child at its cursor, then
    /// checks root-level lenses at main cursor position.
    pub fn focus_down(&mut self, main_cursor_line: usize) -> bool {
        if let Some(idx) = self.focused_root {
            // We're inside a lens — try to refocus a child of the active leaf
            let root = &mut self.roots[idx];
            let leaf = root.active_leaf_mut();
            leaf.refocus_child_at_cursor()
        } else {
            // Not in any lens — try to focus a root lens at main cursor
            if let Some(idx) = self.roots.iter().position(|r| r.parent_line == main_cursor_line) {
                self.focused_root = Some(idx);
                true
            } else {
                false
            }
        }
    }

    /// Open a new lens. If we're inside a lens, it opens as a child of the
    /// active leaf. Otherwise it opens at the root level.
    pub fn open_lens(&mut self, file_buffer: FileBuffer, main_cursor_line: usize) {
        if let Some(idx) = self.focused_root {
            // Open inside the active leaf
            let root = &mut self.roots[idx];
            let leaf = root.active_leaf_mut();
            leaf.open_child(file_buffer);
        } else {
            // Open at root level
            self.open_at_root(file_buffer, main_cursor_line);
        }
    }

    /// Get all root-level lenses for rendering
    pub fn root_layers(&self) -> &[LensLayer] {
        &self.roots
    }
}

impl Default for LensStack {
    fn default() -> Self {
        Self::new()
    }
}

// Legacy compat types — will be removed once search/command UI is rebuilt
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum LensType { FileFinder, Search, Completions, Git, Command }
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum InputPrefix { Filter, Ripgrep, Fzf, AiPrompt, Git }
#[derive(Clone, Debug)]
pub struct SuggestionItem { pub text: String, pub metadata: String, pub icon: char }
#[derive(Clone, Debug)]
pub struct LensBuffer {
    pub visible: bool, pub lens_type: LensType, pub input: String,
    pub input_cursor: usize, pub suggestions_above: Vec<SuggestionItem>,
    pub suggestions_below: Vec<SuggestionItem>, pub selected_index: usize,
    pub prefix: InputPrefix,
}
impl LensBuffer {
    pub fn new() -> Self {
        LensBuffer {
            visible: false, lens_type: LensType::FileFinder, input: String::new(),
            input_cursor: 0, suggestions_above: Vec::new(), suggestions_below: Vec::new(),
            selected_index: 0, prefix: InputPrefix::Filter,
        }
    }
    pub fn is_visible(&self) -> bool { self.visible }
    pub fn show_search(&mut self) { self.visible = true; self.lens_type = LensType::Search; self.input.clear(); self.input_cursor = 0; }
    pub fn show_command(&mut self) { self.visible = true; self.lens_type = LensType::Command; self.input.clear(); self.input_cursor = 0; }
    pub fn hide(&mut self) { self.visible = false; }
}
impl Default for LensBuffer { fn default() -> Self { Self::new() } }

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_lens_initial_window() {
        let fb = FileBuffer::new(
            std::path::PathBuf::from("/tmp/test.rs"),
            (0..20).map(|i| format!("line {}", i)).collect(),
        );
        let layer = LensLayer::from_file(fb, 10);
        assert_eq!(layer.cursor.line, 0);
        assert_eq!(layer.window_top, 0);
        assert_eq!(layer.window_bottom, 2);
    }

    #[test]
    fn test_lens_expands_only_at_edges() {
        let fb = FileBuffer::new(
            std::path::PathBuf::from("/tmp/test.rs"),
            (0..20).map(|i| format!("line {}", i)).collect(),
        );
        let mut layer = LensLayer::from_file(fb, 10);
        assert_eq!((layer.window_top, layer.window_bottom), (0, 2));

        layer.cursor.line = 1;
        layer.expand_to_cursor();
        assert_eq!((layer.window_top, layer.window_bottom), (0, 2));

        layer.cursor.line = 3;
        layer.expand_to_cursor();
        assert_eq!((layer.window_top, layer.window_bottom), (0, 3));

        layer.cursor.line = 1;
        layer.expand_to_cursor();
        assert_eq!((layer.window_top, layer.window_bottom), (0, 3));
    }

    #[test]
    fn test_recursive_lens_tree() {
        // Root buffer → open lens A at line 5 → open lens B inside A at line 2
        let mut stack = LensStack::new();

        let fb_a = FileBuffer::new(
            std::path::PathBuf::from("/tmp/a.rs"),
            (0..10).map(|i| format!("a-line {}", i)).collect(),
        );
        stack.open_lens(fb_a, 5); // Opens at root level
        assert_eq!(stack.depth(), 1);
        assert_eq!(stack.active_leaf().unwrap().file_name, "a.rs");

        // Now open lens B inside A
        let fb_b = FileBuffer::new(
            std::path::PathBuf::from("/tmp/b.rs"),
            (0..10).map(|i| format!("b-line {}", i)).collect(),
        );
        stack.open_lens(fb_b, 0); // Opens as child of active leaf (a.rs)
        assert_eq!(stack.depth(), 2);
        assert_eq!(stack.active_leaf().unwrap().file_name, "b.rs");

        // Navigate up — back to A
        stack.focus_up();
        assert_eq!(stack.depth(), 1);
        assert_eq!(stack.active_leaf().unwrap().file_name, "a.rs");

        // Navigate up — back to root (no active lens)
        stack.focus_up();
        assert_eq!(stack.depth(), 0);
        assert!(!stack.is_active());

        // Navigate down at line 5 — re-enters A
        assert!(stack.focus_down(5));
        assert_eq!(stack.depth(), 1);
        assert_eq!(stack.active_leaf().unwrap().file_name, "a.rs");

        // Navigate down at A's cursor (line 0, where B was opened)
        assert!(stack.focus_down(0));
        assert_eq!(stack.depth(), 2);
        assert_eq!(stack.active_leaf().unwrap().file_name, "b.rs");
    }

    #[test]
    fn test_multiple_lenses_same_level() {
        let mut stack = LensStack::new();

        let fb1 = FileBuffer::new(
            std::path::PathBuf::from("/tmp/x.rs"),
            vec!["x".to_string()],
        );
        let fb2 = FileBuffer::new(
            std::path::PathBuf::from("/tmp/y.rs"),
            vec!["y".to_string()],
        );

        // Open two lenses at different positions in root
        stack.open_at_root(fb1, 5);
        stack.focused_root = None; // Unfocus to open another at root
        stack.open_at_root(fb2, 15);
        stack.focused_root = None;

        assert_eq!(stack.roots.len(), 2);
        assert_eq!(stack.roots[0].parent_line, 5);
        assert_eq!(stack.roots[1].parent_line, 15);

        // Focus into the one at line 5
        assert!(stack.focus_down(5));
        assert_eq!(stack.active_leaf().unwrap().file_name, "x.rs");

        // Go back up
        stack.focus_up();

        // Focus into the one at line 15
        assert!(stack.focus_down(15));
        assert_eq!(stack.active_leaf().unwrap().file_name, "y.rs");
    }
}
