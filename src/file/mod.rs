//! File I/O module - handles loading and saving files

use std::fs;
use std::path::{Path, PathBuf};

/// File buffer - represents a file in memory
#[derive(Clone, Debug)]
pub struct FileBuffer {
    /// File path
    pub path: PathBuf,
    /// File contents (one line per entry)
    pub lines: Vec<String>,
    /// Text encoding (UTF-8 for now)
    pub encoding: String,
    /// Line ending style
    pub line_ending: LineEnding,
}

/// Line ending style
#[derive(Clone, Debug, Copy, PartialEq, Eq)]
pub enum LineEnding {
    LF,   // Unix: \n
    CRLF, // Windows: \r\n
}

impl FileBuffer {
    /// Create new file buffer with content
    pub fn new(path: PathBuf, lines: Vec<String>) -> Self {
        FileBuffer {
            path,
            lines,
            encoding: "UTF-8".to_string(),
            line_ending: LineEnding::LF,
        }
    }

    /// Load file from disk
    pub fn load(path: &Path) -> std::io::Result<Self> {
        let content = fs::read_to_string(path)?;

        // Detect line ending
        let line_ending = if content.contains("\r\n") {
            LineEnding::CRLF
        } else {
            LineEnding::LF
        };

        // Split into lines
        let lines: Vec<String> = if line_ending == LineEnding::CRLF {
            content.split("\r\n").map(|s| s.to_string()).collect()
        } else {
            content.split('\n').map(|s| s.to_string()).collect()
        };

        Ok(FileBuffer {
            path: path.to_path_buf(),
            lines,
            encoding: "UTF-8".to_string(),
            line_ending,
        })
    }

    /// Save file to disk (atomic write)
    pub fn save(&self) -> std::io::Result<()> {
        use std::io::Write;

        let path = &self.path;
        let parent = path.parent().ok_or_else(|| {
            std::io::Error::new(std::io::ErrorKind::InvalidInput, "Invalid file path")
        })?;

        // Create temp file in same directory
        let temp_path = parent.join(format!(
            ".{}.tmp",
            path.file_name().unwrap_or_default().to_string_lossy()
        ));

        // Write to temp file
        let line_ending_str = match self.line_ending {
            LineEnding::CRLF => "\r\n",
            LineEnding::LF => "\n",
        };

        let content = self.lines.join(line_ending_str);
        let mut file = fs::File::create(&temp_path)?;
        file.write_all(content.as_bytes())?;
        drop(file); // Ensure file is closed before rename

        // Atomic rename
        fs::rename(&temp_path, path)?;
        Ok(())
    }

    /// Get line count
    pub fn len(&self) -> usize {
        self.lines.len()
    }

    /// Check if empty
    pub fn is_empty(&self) -> bool {
        self.lines.is_empty()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use tempfile::TempDir;

    #[test]
    fn test_load_file() {
        let temp_dir = TempDir::new().unwrap();
        let file_path = temp_dir.path().join("test.txt");
        fs::write(&file_path, "Line 1\nLine 2\nLine 3").unwrap();

        let buf = FileBuffer::load(&file_path).unwrap();
        assert_eq!(buf.lines.len(), 3);
        assert_eq!(buf.lines[0], "Line 1");
    }

    #[test]
    fn test_save_file() {
        let temp_dir = TempDir::new().unwrap();
        let file_path = temp_dir.path().join("test.txt");

        let buf = FileBuffer::new(
            file_path.clone(),
            vec!["Hello".to_string(), "World".to_string()],
        );
        buf.save().unwrap();

        let content = fs::read_to_string(&file_path).unwrap();
        assert_eq!(content, "Hello\nWorld");
    }

    #[test]
    fn test_detect_crlf() {
        let temp_dir = TempDir::new().unwrap();
        let file_path = temp_dir.path().join("test.txt");
        fs::write(&file_path, "Line 1\r\nLine 2").unwrap();

        let buf = FileBuffer::load(&file_path).unwrap();
        assert_eq!(buf.line_ending, LineEnding::CRLF);
    }
}
