//! Cursor position tracking with bounds checking

/// Represents cursor position in the file
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CursorPosition {
    /// Line number (0-indexed)
    pub line: usize,
    /// Column number (0-indexed)
    pub column: usize,
}

impl CursorPosition {
    /// Create new cursor at position
    pub fn new(line: usize, column: usize) -> Self {
        CursorPosition { line, column }
    }

    /// Move cursor up one line
    pub fn move_up(&mut self, _buffer_lines: &[String]) {
        if self.line > 0 {
            self.line -= 1;
            self.clamp_column(_buffer_lines);
        }
    }

    /// Move cursor down one line
    pub fn move_down(&mut self, buffer_lines: &[String]) {
        if self.line < buffer_lines.len().saturating_sub(1) {
            self.line += 1;
            self.clamp_column(buffer_lines);
        }
    }

    /// Move cursor left one character
    pub fn move_left(&mut self) {
        if self.column > 0 {
            self.column -= 1;
        }
    }

    /// Move cursor right one character (with wrapping to next line)
    pub fn move_right(&mut self, buffer_lines: &[String]) {
        if self.line < buffer_lines.len() {
            let line_len = buffer_lines[self.line].len();
            if self.column < line_len {
                self.column += 1;
            } else if self.line < buffer_lines.len() - 1 {
                // Wrap to next line
                self.line += 1;
                self.column = 0;
            }
        }
    }

    /// Clamp column to valid range for current line
    fn clamp_column(&mut self, buffer_lines: &[String]) {
        if self.line < buffer_lines.len() {
            let max_col = buffer_lines[self.line].len();
            if self.column > max_col {
                self.column = max_col;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_lines() -> Vec<String> {
        vec!["Hello".to_string(), "World".to_string(), "Test".to_string()]
    }

    #[test]
    fn test_move_down() {
        let mut cursor = CursorPosition::new(0, 2);
        let lines = make_lines();
        cursor.move_down(&lines);
        assert_eq!(cursor.line, 1);
    }

    #[test]
    fn test_move_up() {
        let mut cursor = CursorPosition::new(1, 0);
        let lines = make_lines();
        cursor.move_up(&lines);
        assert_eq!(cursor.line, 0);
    }

    #[test]
    fn test_move_up_at_start() {
        let mut cursor = CursorPosition::new(0, 0);
        let lines = make_lines();
        cursor.move_up(&lines);
        assert_eq!(cursor.line, 0);
    }

    #[test]
    fn test_move_down_at_end() {
        let mut cursor = CursorPosition::new(2, 0);
        let lines = make_lines();
        cursor.move_down(&lines);
        assert_eq!(cursor.line, 2);
    }

    #[test]
    fn test_clamp_column() {
        let mut cursor = CursorPosition::new(0, 10); // "Hello" has 5 chars
        let lines = make_lines();
        cursor.clamp_column(&lines);
        assert_eq!(cursor.column, 5);
    }
}
