//! Editor buffer - wraps FileBuffer with editing state and auto-save

use crate::file::FileBuffer;

/// Editor wrapper around FileBuffer with auto-save state
#[derive(Clone, Debug)]
pub struct EditorBuffer {
    /// Underlying file buffer
    inner: FileBuffer,
}

impl EditorBuffer {
    /// Create new editor buffer from file buffer
    pub fn from(file_buffer: FileBuffer) -> Self {
        EditorBuffer {
            inner: file_buffer,
        }
    }

    /// Get all lines
    pub fn lines(&self) -> &[String] {
        &self.inner.lines
    }

    /// Get mutable lines
    pub fn lines_mut(&mut self) -> &mut Vec<String> {
        &mut self.inner.lines
    }

    /// Get total line count
    pub fn len(&self) -> usize {
        self.inner.lines.len()
    }

    /// Check if buffer is empty
    pub fn is_empty(&self) -> bool {
        self.inner.lines.is_empty()
    }

    /// Get line by index
    pub fn line(&self, i: usize) -> Option<&str> {
        self.inner.lines.get(i).map(|s| s.as_str())
    }

    /// Get mutable line by index
    pub fn line_mut(&mut self, i: usize) -> Option<&mut String> {
        self.inner.lines.get_mut(i)
    }

    /// Insert character at position
    pub fn insert_char(&mut self, line: usize, col: usize, ch: char) -> std::io::Result<()> {
        if line < self.inner.lines.len() {
            let line_str = &mut self.inner.lines[line];
            if col <= line_str.len() {
                line_str.insert(col, ch);
                Ok(())
            } else {
                Err(std::io::Error::new(
                    std::io::ErrorKind::InvalidInput,
                    "Column out of bounds",
                ))
            }
        } else {
            Err(std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                "Line out of bounds",
            ))
        }
    }

    /// Delete character at position
    pub fn delete_char(&mut self, line: usize, col: usize) -> std::io::Result<()> {
        if line < self.inner.lines.len() {
            let line_str = &mut self.inner.lines[line];
            if col < line_str.len() {
                line_str.remove(col);
                Ok(())
            } else {
                Err(std::io::Error::new(
                    std::io::ErrorKind::InvalidInput,
                    "Column out of bounds",
                ))
            }
        } else {
            Err(std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                "Line out of bounds",
            ))
        }
    }

    /// Insert new line
    pub fn insert_line(&mut self, line: usize, content: String) -> std::io::Result<()> {
        if line <= self.inner.lines.len() {
            self.inner.lines.insert(line, content);
            Ok(())
        } else {
            Err(std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                "Line out of bounds",
            ))
        }
    }

    /// Get file path
    pub fn path(&self) -> &std::path::Path {
        &self.inner.path
    }

    /// Save buffer to disk
    pub fn save(&mut self) -> std::io::Result<()> {
        self.inner.save()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_insert_char() {
        let file_buf = FileBuffer::new(
            std::path::PathBuf::from("/tmp/test.txt"),
            vec!["Hello".to_string()],
        );
        let mut editor_buf = EditorBuffer::from(file_buf);
        editor_buf.insert_char(0, 5, '!').unwrap();
        assert_eq!(editor_buf.line(0), Some("Hello!"));
    }

    #[test]
    fn test_delete_char() {
        let file_buf = FileBuffer::new(
            std::path::PathBuf::from("/tmp/test.txt"),
            vec!["Hello".to_string()],
        );
        let mut editor_buf = EditorBuffer::from(file_buf);
        editor_buf.delete_char(0, 4).unwrap();
        assert_eq!(editor_buf.line(0), Some("Hell"));
    }
}
