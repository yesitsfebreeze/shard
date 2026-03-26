//! Lens - stacked buffer system for drilling into code
//!
//! A lens splits the outer buffer at the cursor line and injects a focused
//! view of another file. The parent buffer remains visible above/below.
//! As you move within a lens, it grows. Alt+Up/Down navigates the stack.

use crate::editor::CursorPosition;
use crate::editor::EditorBuffer;
use crate::file::FileBuffer;

/// A single lens layer: a focused buffer injected into the parent
#[derive(Clone, Debug)]
pub struct LensLayer {
    /// The buffer being viewed in this lens
    pub buffer: EditorBuffer,
    /// Cursor position within this lens buffer
    pub cursor: CursorPosition,
    /// How many lines above cursor to show (starts at ~5, grows)
    pub radius_above: usize,
    /// How many lines below cursor to show (starts at ~5, grows)
    pub radius_below: usize,
    /// Number of cursor moves since opening (drives growth)
    pub move_count: usize,
    /// The line in the PARENT buffer where this lens was inserted
    pub parent_line: usize,
    /// File path for display in separator
    pub file_name: String,
    /// Whether this layer has unsaved changes
    pub dirty: bool,
}

/// Initial visible radius above/below cursor when a lens opens
const INITIAL_RADIUS: usize = 5;
/// How many moves before the radius grows by 1
const MOVES_PER_GROWTH: usize = 1;

impl LensLayer {
    /// Create a new lens layer from a file
    pub fn from_file(file_buffer: FileBuffer, parent_line: usize) -> Self {
        let file_name = file_buffer
            .path
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("untitled")
            .to_string();

        LensLayer {
            buffer: EditorBuffer::from(file_buffer),
            cursor: CursorPosition::new(0, 0),
            radius_above: INITIAL_RADIUS,
            radius_below: INITIAL_RADIUS,
            move_count: 0,
            parent_line,
            file_name,
            dirty: false,
        }
    }

    /// Record a cursor move and maybe grow the visible radius
    pub fn record_move(&mut self) {
        self.move_count += 1;
        // Grow radius by 1 for every MOVES_PER_GROWTH cursor moves
        let target_radius = INITIAL_RADIUS + self.move_count / MOVES_PER_GROWTH;
        self.radius_above = target_radius.min(self.buffer.len());
        self.radius_below = target_radius.min(self.buffer.len());
    }

    /// Get the range of visible lines in this lens buffer
    pub fn visible_range(&self) -> (usize, usize) {
        let start = self.cursor.line.saturating_sub(self.radius_above);
        let end = (self.cursor.line + self.radius_below + 1).min(self.buffer.len());
        (start, end)
    }

    /// Total visible height of this lens
    pub fn visible_height(&self) -> usize {
        let (start, end) = self.visible_range();
        end - start + 2 // +2 for top and bottom separators
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
    fn test_lens_layer_initial_radius() {
        let fb = FileBuffer::new(
            std::path::PathBuf::from("/tmp/test.rs"),
            (0..20).map(|i| format!("line {}", i)).collect(),
        );
        let layer = LensLayer::from_file(fb, 10);
        assert_eq!(layer.radius_above, INITIAL_RADIUS);
        assert_eq!(layer.radius_below, INITIAL_RADIUS);
        assert_eq!(layer.cursor.line, 0);
    }

    #[test]
    fn test_lens_layer_grows_on_move() {
        let fb = FileBuffer::new(
            std::path::PathBuf::from("/tmp/test.rs"),
            (0..50).map(|i| format!("line {}", i)).collect(),
        );
        let mut layer = LensLayer::from_file(fb, 10);

        // After 10 moves, radius should grow by 10
        for _ in 0..10 {
            layer.record_move();
        }
        assert_eq!(layer.radius_above, INITIAL_RADIUS + 10);
        assert_eq!(layer.radius_below, INITIAL_RADIUS + 10);
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
    fn test_visible_range() {
        let fb = FileBuffer::new(
            std::path::PathBuf::from("/tmp/test.rs"),
            (0..20).map(|i| format!("line {}", i)).collect(),
        );
        let mut layer = LensLayer::from_file(fb, 10);
        layer.cursor = CursorPosition::new(10, 0);

        let (start, end) = layer.visible_range();
        assert_eq!(start, 5);  // 10 - 5
        assert_eq!(end, 16);   // 10 + 5 + 1
    }
}
