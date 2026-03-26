//! Rendering - builds terminal output with centered cursor display
//!
//! Renders on demand when state changes (event-driven).
//! No fixed frame rate - redraw only when necessary.
//!
//! Layout:
//! - Top status bar (file name, mode)
//! - Content area with cursor always centered
//! - Bottom status bar (line:col, total lines)

use super::viewport::Viewport;
use crate::editor::{CursorPosition, LensBuffer};

/// Render current editor state to terminal output
///
/// Returns a string containing ANSI-escaped terminal commands to display the current state.
/// In Lens mode: input line at screen center, suggestions above/below, buffer content flows around
/// In normal mode: buffer centered with cursor at center line (traditional editing)
pub fn render_frame(
    lines: &[String],
    cursor: &CursorPosition,
    _viewport: &Viewport,
    width: usize,
    height: usize,
    lens: &LensBuffer,
) -> String {
    let mut frame = String::new();

    // Clear screen first
    frame.push_str("\x1b[2J\x1b[H");

    // Height breakdown
    let content_height = height.saturating_sub(2); // Reserve 1 for top, 1 for bottom
    let center_row = content_height / 2;

    // Top status bar
    let top_status = "Shards TUI - Interactive Editor";
    frame.push_str("\x1b[7m"); // Invert colors
    frame.push_str(&format!("{:<width$}", top_status, width = width));
    frame.push_str("\x1b[0m"); // Reset
    frame.push('\n');

    // Calculate which lines to display (centered on cursor)
    let (top_line, _visual_cursor_row) =
        Viewport::center_on_cursor(cursor.line, lines.len(), content_height);

    // Render content area with cursor centered
    for visual_row in 0..content_height {
        let buffer_line_idx = top_line + visual_row;

        let line_str = if buffer_line_idx < lines.len() {
            lines[buffer_line_idx].as_str()
        } else {
            "" // Virtual lines below EOF
        };

        // Truncate or pad line to screen width
        let display_line = if line_str.len() > width {
            &line_str[..width]
        } else {
            line_str
        };

        // Highlight cursor line (cursor is always at center_row)
        if visual_row == center_row && buffer_line_idx == cursor.line {
            // Cursor line - invert background
            frame.push_str("\x1b[7m"); // Invert colors
            frame.push_str(&format!("{:<width$}", display_line, width = width));
            frame.push_str("\x1b[0m"); // Reset
        } else {
            frame.push_str(&format!("{:<width$}", display_line, width = width));
        }

        frame.push('\n');
    }

    // Bottom status bar
    let status = format!(
        "Line {}:{} | {} lines",
        cursor.line + 1,
        cursor.column + 1,
        lines.len(),
    );
    frame.push_str("\x1b[7m"); // Invert colors for status bar
    frame.push_str(&format!("{:<width$}", status, width = width));
    frame.push_str("\x1b[0m"); // Reset

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
