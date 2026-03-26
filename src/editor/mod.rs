//! Editor module - manages file buffer, cursor, and editing state

pub mod buffer;
pub mod lens;
pub mod cursor;
pub mod stack;

// Re-export types for public API
pub use buffer::EditorBuffer;
pub use lens::{LensBuffer, LensLayer, LensStack, LensType, InputPrefix, SuggestionItem};
pub use cursor::CursorPosition;
pub use stack::ContextStack;

use crate::file::FileBuffer;

/// Main editor state
pub struct Editor {
    /// Current buffer being edited
    pub buffer: EditorBuffer,
    /// Current cursor position
    pub cursor: CursorPosition,
    /// Stack of previous file contexts for navigation
    pub context_stack: ContextStack,
    /// Whether buffer has unsaved changes
    pub dirty: bool,
}

impl Editor {
    /// Create new editor with file
    pub fn new(file_buffer: FileBuffer) -> Self {
        Editor {
            buffer: EditorBuffer::from(file_buffer),
            cursor: CursorPosition::new(0, 0),
            context_stack: ContextStack::new(),
            dirty: false,
        }
    }

    /// Get current file buffer state
    pub fn buffer(&self) -> &EditorBuffer {
        &self.buffer
    }

    /// Get mutable reference to buffer
    pub fn buffer_mut(&mut self) -> &mut EditorBuffer {
        &mut self.buffer
    }

    /// Get current cursor position
    pub fn cursor(&self) -> &CursorPosition {
        &self.cursor
    }

    /// Get mutable cursor reference
    pub fn cursor_mut(&mut self) -> &mut CursorPosition {
        &mut self.cursor
    }

    /// Mark buffer as dirty (unsaved changes)
    pub fn set_dirty(&mut self) {
        self.dirty = true;
    }

    /// Clear dirty flag
    pub fn clear_dirty(&mut self) {
        self.dirty = false;
    }

    /// Save buffer to disk
    pub fn save(&mut self) -> std::io::Result<()> {
        self.buffer.save()?;
        self.dirty = false;
        Ok(())
    }
}
