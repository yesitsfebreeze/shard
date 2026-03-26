//! Rendering - builds terminal output with centered cursor and optional lens display
//!
//! Two modes:
//! 1. Normal: Cursor centered, line numbers visible
//! 2. Lens: Input line at center, suggestions above/below
//!
//! Layout:
//! - Top status bar
//! - Content with line numbers and cursor centered
//! - Bottom status bar

use super::viewport::Viewport;
use crate::editor::CursorPosition;
use crate::editor::LensBuffer;

/// Render current editor state to terminal output
pub fn render_frame(
    lines: &[String],
    cursor: &CursorPosition,
    _viewport: &Viewport,
    width: usize,
    height: usize,
    _lens: &LensBuffer,
) -> String {
    let mut frame = String::new();

    // Clear screen
    frame.push_str("\x1b[2J\x1b[H");

    // Height breakdown
    let content_height = height.saturating_sub(2); // Reserve for top & bottom bars
    let center_row = content_height / 2;

    // Top status bar
    let top_status = "Shards TUI - Interactive Editor";
    frame.push_str("\x1b[7m");
    frame.push_str(&format!("{:<width$}", top_status, width = width));
    frame.push_str("\x1b[0m\r\n");

    // Calculate line number column width
    let line_num_width = ((lines.len() as f64).log10().ceil() as usize).max(3);
    let gutter_width = line_num_width + 1; // numbers + space
    let content_width = width.saturating_sub(gutter_width);

    // Calculate viewport
    let (top_line, _) = Viewport::center_on_cursor(cursor.line, lines.len(), content_height);

    // Render content with line numbers
    for visual_row in 0..content_height {
        let buffer_line_idx = top_line + visual_row;
        let is_cursor_line = buffer_line_idx == cursor.line;

        // Render line number
        if buffer_line_idx < lines.len() {
            let line_num = if is_cursor_line {
                // Current line: absolute, left-aligned
                format!("{}", buffer_line_idx + 1)
            } else {
                // Other lines: relative distance, right-aligned
                format!("{}", if buffer_line_idx < cursor.line {
                    cursor.line - buffer_line_idx
                } else {
                    buffer_line_idx - cursor.line
                })
            };
            if is_cursor_line {
                frame.push_str(&format!("{:<width$} ", line_num, width = line_num_width));
            } else {
                frame.push_str(&format!("{:>width$} ", line_num, width = line_num_width));
            }
        } else {
            // Virtual line below EOF
            frame.push_str(&format!("{:>width$} ", "", width = line_num_width));
        }

        // Render line content
        let line_str = if buffer_line_idx < lines.len() {
            &lines[buffer_line_idx]
        } else {
            ""
        };

        let display = if line_str.len() > content_width {
            &line_str[..content_width]
        } else {
            line_str
        };

        frame.push_str(&format!("{:<width$}", display, width = content_width));
        frame.push_str("\r\n");
    }

    // Bottom status bar
    let bottom_status = format!(
        "Line {}:{} | {} lines",
        cursor.line + 1,
        cursor.column + 1,
        lines.len()
    );
    frame.push_str("\x1b[7m");
    frame.push_str(&format!("{:<width$}", bottom_status, width = width));
    frame.push_str("\x1b[0m");

    // Position terminal cursor at center line with column offset
    let cursor_screen_row = 2 + center_row; // +2 for top bar and 0-indexing
    let cursor_screen_col = gutter_width + (cursor.column + 1).min(content_width);
    frame.push_str(&format!("\x1b[{};{}H", cursor_screen_row, cursor_screen_col));

    frame
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_render_simple_frame() {
        let lines = vec!["Hello".to_string(), "World".to_string()];
        let cursor = CursorPosition { line: 0, column: 0 };
        let viewport = Viewport::new(5);
        let lens = LensBuffer::new();

        let frame = render_frame(&lines, &cursor, &viewport, 20, 7, &lens);
        assert!(frame.contains("Hello"));
        assert!(frame.contains("World"));
        assert!(frame.contains("Line"));
    }
}
