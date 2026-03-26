//! Rendering - builds terminal output with centered cursor display
//!
//! Renders on demand when state changes (event-driven).
//! No fixed frame rate - redraw only when necessary.

use super::viewport::Viewport;
use crate::editor::CursorPosition;

/// Render current editor state to terminal output
///
/// Returns a string containing ANSI-escaped terminal commands to display the current state.
/// Called after each event that changes editor state (cursor movement, text insertion, etc.).
pub fn render_frame(
    lines: &[String],
    cursor: &CursorPosition,
    viewport: &Viewport,
    width: usize,
    _height: usize,
) -> String {
    let mut frame = String::new();

    // Get visible line range
    let visible_range = viewport.visible_range();

    // Calculate cursor visual position
    let (_, visual_cursor_row) =
        Viewport::center_on_cursor(cursor.line, lines.len(), viewport.height);

    // Render each visible line
    let mut visual_row = 0;
    for line_idx in visible_range {
        if visual_row >= viewport.height {
            break;
        }

        let line_str = if line_idx < lines.len() {
            lines[line_idx].as_str()
        } else {
            "" // Virtual lines below EOF
        };

        // Truncate line to screen width if needed
        let display_line = if line_str.len() > width {
            &line_str[..width]
        } else {
            line_str
        };

        // Highlight cursor line (with spaces if empty)
        if visual_row == visual_cursor_row {
            // Cursor line - invert background
            frame.push_str("\x1b[7m"); // Invert colors
            frame.push_str(&format!("{:<width$}", display_line, width = width));
            frame.push_str("\x1b[0m"); // Reset colors
        } else {
            frame.push_str(&format!("{:<width$}", display_line, width = width));
        }

        frame.push('\n');
        visual_row += 1;
    }

    // Pad remaining rows with blank lines
    while visual_row < viewport.height {
        frame.push('\n');
        visual_row += 1;
    }

    // Status bar (last line)
    let status = format!(
        "{}:{} | {} lines | {}",
        cursor.line + 1,
        cursor.column + 1,
        lines.len(),
        "Ready"
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

        let frame = render_frame(&lines, &cursor, &viewport, 20, 5);
        assert!(frame.contains("Hello"));
        assert!(frame.contains("World"));
    }
}
