//! Context stack - manages file navigation history

use super::CursorPosition;

/// Saved editor context for file navigation
#[derive(Clone, Debug)]
pub struct ContextEntry {
    /// File path
    pub file_path: std::path::PathBuf,
    /// Cursor position in that file
    pub cursor: CursorPosition,
    /// Top line in viewport
    pub viewport_top: usize,
}

impl ContextEntry {
    /// Create new context entry
    pub fn new(file_path: std::path::PathBuf, cursor: CursorPosition, viewport_top: usize) -> Self {
        ContextEntry {
            file_path,
            cursor,
            viewport_top,
        }
    }
}

/// Stack of editor contexts for file navigation
#[derive(Debug)]
pub struct ContextStack {
    stack: Vec<ContextEntry>,
}

impl ContextStack {
    /// Create new empty context stack
    pub fn new() -> Self {
        ContextStack { stack: Vec::new() }
    }

    /// Push context onto stack
    pub fn push(&mut self, entry: ContextEntry) {
        self.stack.push(entry);
    }

    /// Pop context from stack
    pub fn pop(&mut self) -> Option<ContextEntry> {
        self.stack.pop()
    }

    /// Peek at top context without removing
    pub fn peek(&self) -> Option<&ContextEntry> {
        self.stack.last()
    }

    /// Get stack depth
    pub fn depth(&self) -> usize {
        self.stack.len()
    }

    /// Check if stack is empty
    pub fn is_empty(&self) -> bool {
        self.stack.is_empty()
    }
}

impl Default for ContextStack {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_push_pop() {
        let mut stack = ContextStack::new();
        let entry = ContextEntry::new(
            std::path::PathBuf::from("/tmp/test.txt"),
            CursorPosition::new(10, 5),
            0,
        );
        stack.push(entry.clone());
        assert_eq!(stack.depth(), 1);

        let popped = stack.pop().unwrap();
        assert_eq!(popped.cursor.line, 10);
        assert_eq!(stack.depth(), 0);
    }

    #[test]
    fn test_peek() {
        let mut stack = ContextStack::new();
        let entry = ContextEntry::new(
            std::path::PathBuf::from("/tmp/test.txt"),
            CursorPosition::new(5, 0),
            0,
        );
        stack.push(entry);
        assert_eq!(stack.peek().unwrap().cursor.line, 5);
        assert_eq!(stack.depth(), 1); // Peek doesn't remove
    }
}
