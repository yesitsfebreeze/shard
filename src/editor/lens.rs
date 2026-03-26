//! Lens - stacked buffer system for drilling into code
//!
//! A lens splits the outer buffer at the cursor line and injects a focused
//! view of another file. The parent buffer remains visible above/below.
//! As you move within a lens, it grows. Alt+Up/Down navigates the stack.

use crate::editor::CursorPosition;
use crate::editor::EditorBuffer;
use crate::file::FileBuffer;

/// A single lens layer: a focused buffer injected into the parent
///
/// The lens tracks a visible window defined by `window_top` and `window_bottom`.
/// It starts small (cursor ± INITIAL_PADDING) and only expands when the cursor
/// moves past the current window edge into new territory. Moving back within
/// already-revealed area does NOT grow the window.
#[derive(Clone, Debug)]
pub struct LensLayer {
    /// The buffer being viewed in this lens
    pub buffer: EditorBuffer,
    /// Cursor position within this lens buffer
    pub cursor: CursorPosition,
    /// First visible line (inclusive) — only grows upward when cursor goes above
    pub window_top: usize,
    /// Last visible line (inclusive) — only grows downward when cursor goes below
    pub window_bottom: usize,
    /// The line in the PARENT buffer where this lens was inserted
    pub parent_line: usize,
    /// File path for display in separator
    pub file_name: String,
    /// Whether this layer has unsaved changes
    pub dirty: bool,
}

/// Initial padding above/below cursor when a lens opens
const INITIAL_PADDING: usize = 2;

impl LensLayer {
    /// Create a new lens layer from a file at a given line
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
        }
    }

    /// Called after cursor moves. Expands the window only if the cursor
    /// has moved past the current edge (into new territory).
    pub fn expand_to_cursor(&mut self) {
        if self.cursor.line < self.window_top {
            self.window_top = self.cursor.line;
        }
        if self.cursor.line > self.window_bottom {
            self.window_bottom = self.cursor.line;
        }
        // Clamp to buffer bounds
        let max_line = self.buffer.len().saturating_sub(1);
        self.window_bottom = self.window_bottom.min(max_line);
    }

    /// Get the range of visible lines: [window_top, window_bottom] inclusive
    pub fn visible_range(&self) -> (usize, usize) {
        (self.window_top, self.window_bottom + 1) // +1 for exclusive end
    }

    /// Total visible height of this lens (content + 2 separators)
    pub fn visible_height(&self) -> usize {
        (self.window_bottom - self.window_top + 1) + 2
    }

    /// Get visible lines for rendering
    pub fn visible_lines(&self) -> &[String] {
        let (start, end) = self.visible_range();
        &self.buffer.lines()[start..end]
    }
}

/// The lens stack: manages nested buffer layers
#[derive(Debug)]
pub struct LensStack {
    /// Stack of lens layers (last = deepest/active)
    layers: Vec<LensLayer>,
}

impl LensStack {
    pub fn new() -> Self {
        LensStack {
            layers: Vec::new(),
        }
    }

    /// Push a new lens layer (drill into a file)
    pub fn push(&mut self, layer: LensLayer) {
        self.layers.push(layer);
    }

    /// Pop the top lens layer (navigate up to parent)
    /// Returns the popped layer so caller can save state if needed
    pub fn pop(&mut self) -> Option<LensLayer> {
        self.layers.pop()
    }

    /// Get the active (topmost) lens layer
    pub fn active(&self) -> Option<&LensLayer> {
        self.layers.last()
    }

    /// Get mutable reference to active lens layer
    pub fn active_mut(&mut self) -> Option<&mut LensLayer> {
        self.layers.last_mut()
    }

    /// How many lens layers deep we are
    pub fn depth(&self) -> usize {
        self.layers.len()
    }

    /// Check if any lens is open
    pub fn is_active(&self) -> bool {
        !self.layers.is_empty()
    }

    /// Get all layers for rendering (from outermost to innermost)
    pub fn layers(&self) -> &[LensLayer] {
        &self.layers
    }
}

impl Default for LensStack {
    fn default() -> Self {
        Self::new()
    }
}

// Keep the old LensBuffer types around for compatibility during transition
// These will be removed once the full lens stack is wired up

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum LensType {
    FileFinder,
    Search,
    Completions,
    Git,
    Command,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum InputPrefix {
    Filter,
    Ripgrep,
    Fzf,
    AiPrompt,
    Git,
}

#[derive(Clone, Debug)]
pub struct SuggestionItem {
    pub text: String,
    pub metadata: String,
    pub icon: char,
}

#[derive(Clone, Debug)]
pub struct LensBuffer {
    pub visible: bool,
    pub lens_type: LensType,
    pub input: String,
    pub input_cursor: usize,
    pub suggestions_above: Vec<SuggestionItem>,
    pub suggestions_below: Vec<SuggestionItem>,
    pub selected_index: usize,
    pub prefix: InputPrefix,
}

impl LensBuffer {
    pub fn new() -> Self {
        LensBuffer {
            visible: false,
            lens_type: LensType::FileFinder,
            input: String::new(),
            input_cursor: 0,
            suggestions_above: Vec::new(),
            suggestions_below: Vec::new(),
            selected_index: 0,
            prefix: InputPrefix::Filter,
        }
    }

    pub fn is_visible(&self) -> bool {
        self.visible
    }

    pub fn show_search(&mut self) {
        self.visible = true;
        self.lens_type = LensType::Search;
        self.input.clear();
        self.input_cursor = 0;
    }

    pub fn show_command(&mut self) {
        self.visible = true;
        self.lens_type = LensType::Command;
        self.input.clear();
        self.input_cursor = 0;
    }

    pub fn hide(&mut self) {
        self.visible = false;
    }
}

impl Default for LensBuffer {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_lens_initial_window() {
        // Opening at line 0 of a 20-line file: window = [0, 2] (cursor ± 2)
        let fb = FileBuffer::new(
            std::path::PathBuf::from("/tmp/test.rs"),
            (0..20).map(|i| format!("line {}", i)).collect(),
        );
        let layer = LensLayer::from_file(fb, 10);
        assert_eq!(layer.cursor.line, 0);
        assert_eq!(layer.window_top, 0);
        assert_eq!(layer.window_bottom, 2); // 0 + INITIAL_PADDING
    }

    #[test]
    fn test_lens_expands_only_at_edges() {
        let fb = FileBuffer::new(
            std::path::PathBuf::from("/tmp/test.rs"),
            (0..20).map(|i| format!("line {}", i)).collect(),
        );
        let mut layer = LensLayer::from_file(fb, 10);
        // Initial window: [0, 2]
        assert_eq!(layer.window_top, 0);
        assert_eq!(layer.window_bottom, 2);

        // Move cursor to line 1 (still within window) — no expansion
        layer.cursor.line = 1;
        layer.expand_to_cursor();
        assert_eq!(layer.window_top, 0);
        assert_eq!(layer.window_bottom, 2);

        // Move cursor to line 3 (past window_bottom=2) — expands bottom
        layer.cursor.line = 3;
        layer.expand_to_cursor();
        assert_eq!(layer.window_top, 0);
        assert_eq!(layer.window_bottom, 3);

        // Move cursor back to line 1 — no shrink
        layer.cursor.line = 1;
        layer.expand_to_cursor();
        assert_eq!(layer.window_top, 0);
        assert_eq!(layer.window_bottom, 3);

        // Move cursor to line 7 — expands to 7
        layer.cursor.line = 7;
        layer.expand_to_cursor();
        assert_eq!(layer.window_bottom, 7);
    }

    #[test]
    fn test_lens_visible_range() {
        let fb = FileBuffer::new(
            std::path::PathBuf::from("/tmp/test.rs"),
            (0..20).map(|i| format!("line {}", i)).collect(),
        );
        let layer = LensLayer::from_file(fb, 10);
        let (start, end) = layer.visible_range();
        assert_eq!(start, 0);
        assert_eq!(end, 3); // window_bottom(2) + 1 exclusive
    }

    #[test]
    fn test_lens_stack_push_pop() {
        let mut stack = LensStack::new();
        assert!(!stack.is_active());

        let fb = FileBuffer::new(
            std::path::PathBuf::from("/tmp/a.rs"),
            vec!["hello".to_string()],
        );
        stack.push(LensLayer::from_file(fb, 5));
        assert!(stack.is_active());
        assert_eq!(stack.depth(), 1);

        let fb2 = FileBuffer::new(
            std::path::PathBuf::from("/tmp/b.rs"),
            vec!["world".to_string()],
        );
        stack.push(LensLayer::from_file(fb2, 3));
        assert_eq!(stack.depth(), 2);
        assert_eq!(stack.active().unwrap().file_name, "b.rs");

        stack.pop();
        assert_eq!(stack.depth(), 1);
        assert_eq!(stack.active().unwrap().file_name, "a.rs");
    }

    #[test]
    fn test_from_file_at_middle() {
        let fb = FileBuffer::new(
            std::path::PathBuf::from("/tmp/test.rs"),
            (0..20).map(|i| format!("line {}", i)).collect(),
        );
        let layer = LensLayer::from_file_at(fb, 5, 10);
        assert_eq!(layer.cursor.line, 10);
        assert_eq!(layer.window_top, 8);   // 10 - 2
        assert_eq!(layer.window_bottom, 12); // 10 + 2
    }
}
