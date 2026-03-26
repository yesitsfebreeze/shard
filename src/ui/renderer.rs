//! Rendering - builds terminal output with cursor ALWAYS at vertical center
//!
//! The cursor line is always at the center row of the content area.
//! When near the top of the file, blank lines pad above.
//! When near the bottom, blank lines pad below.
//!
//! Layout:
//! - Top status bar
//! - Content area: [blank padding] [buffer lines] [blank padding]
//!   with cursor line always at center_row
//! - Bottom status bar

use super::viewport::Viewport;
use crate::editor::CursorPosition;
use crate::editor::LensBuffer;

/// Render current editor state to terminal output.
/// The cursor line is ALWAYS at the vertical center of the content area.
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

    let content_height = height.saturating_sub(2);
    let center_row = content_height / 2;

    // Line number gutter
    let line_num_width = ((lines.len() as f64).log10().ceil() as usize).max(3);
    let gutter_width = line_num_width + 1;
    let content_width = width.saturating_sub(gutter_width);

    // Top status bar
    let top_status = "Shards TUI - Interactive Editor";
    frame.push_str("\x1b[7m");
    frame.push_str(&format!("{:<width$}", top_status, width = width));
    frame.push_str("\x1b[0m\r\n");

    // The cursor line always maps to center_row.
    // Work backwards: what buffer line maps to visual row 0?
    // buffer_line_at_row(r) = cursor.line - (center_row - r)
    //                       = cursor.line - center_row + r
    // So the buffer index for visual_row r is: cursor.line as i64 - center_row as i64 + r as i64
    // If that's negative or >= lines.len(), it's a blank padding row.

    let base: i64 = cursor.line as i64 - center_row as i64;

    for visual_row in 0..content_height {
        let buf_idx = base + visual_row as i64;

        if buf_idx >= 0 && (buf_idx as usize) < lines.len() {
            let buf_line = buf_idx as usize;
            let is_cursor_line = buf_line == cursor.line;

            // Line number
            let line_num = if is_cursor_line {
                format!("{}", buf_line + 1)
            } else if buf_line < cursor.line {
                format!("{}", cursor.line - buf_line)
            } else {
                format!("{}", buf_line - cursor.line)
            };

            if is_cursor_line {
                frame.push_str(&format!("{:<width$} ", line_num, width = line_num_width));
            } else {
                frame.push_str(&format!("{:>width$} ", line_num, width = line_num_width));
            }

            // Line content
            let line_str = &lines[buf_line];
            let display = if line_str.len() > content_width {
                &line_str[..content_width]
            } else {
                line_str.as_str()
            };
            frame.push_str(&format!("{:<width$}", display, width = content_width));
        } else {
            // Blank padding row (above first line or below last line)
            frame.push_str(&format!("{:>width$} ", "~", width = line_num_width));
            frame.push_str(&format!("{:<width$}", "", width = content_width));
        }

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

    // Terminal cursor always at center_row, column offset by gutter
    let cursor_screen_row = 2 + center_row; // row 1 = top bar, row 2 = first content row
    let cursor_screen_col = gutter_width + (cursor.column + 1).min(content_width);
    frame.push_str(&format!("\x1b[{};{}H", cursor_screen_row, cursor_screen_col));

    frame
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_cursor_always_centered() {
        let lines: Vec<String> = (0..100).map(|i| format!("Line {}", i)).collect();
        let lens = LensBuffer::new();
        let viewport = Viewport::new(20);

        // Cursor at line 0 — should still be at center
        let cursor = CursorPosition { line: 0, column: 0 };
        let frame = render_frame(&lines, &cursor, &viewport, 40, 22, &lens);
        // The frame should contain tildes for blank padding above line 0
        assert!(frame.contains("~"));
        assert!(frame.contains("Line 0"));

        // Cursor at line 50 — middle of file, no padding needed
        let cursor = CursorPosition { line: 50, column: 0 };
        let frame = render_frame(&lines, &cursor, &viewport, 40, 22, &lens);
        assert!(frame.contains("Line 50"));
        assert!(!frame.contains("~"));
    }

    #[test]
    fn test_render_has_status_bars() {
        let lines = vec!["Hello".to_string(), "World".to_string()];
        let cursor = CursorPosition { line: 0, column: 0 };
        let viewport = Viewport::new(5);
        let lens = LensBuffer::new();

        let frame = render_frame(&lines, &cursor, &viewport, 40, 7, &lens);
        assert!(frame.contains("Shards TUI"));
        assert!(frame.contains("Line 1:1"));
    }
}
