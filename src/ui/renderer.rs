//! Rendering - builds terminal output with cursor ALWAYS at vertical center
//!
//! The cursor line is always at the center row of the content area.
//! When a lens is active, the parent buffer is split at the lens insertion
//! point and the lens content is rendered between the halves with separators.
//!
//! Layout:
//! - Top status bar
//! - Content area (parent buffer, possibly split by lens layers)
//! - Bottom status bar

use super::viewport::Viewport;
use crate::editor::{CursorPosition, LensBuffer, LensStack};

/// A renderable row — either from the main buffer, a lens, a separator, or blank
enum Row {
    /// Main buffer line: (buffer_line_index)
    MainBuffer(usize),
    /// Lens buffer line: (layer_index, buffer_line_index)
    LensLine(usize, usize),
    /// Separator line with label
    Separator(String),
    /// Blank padding
    Blank,
}

/// Build the full sequence of rows centered on the active cursor.
fn build_row_map(
    main_lines_len: usize,
    main_cursor_line: usize,
    lens_stack: &LensStack,
    content_height: usize,
) -> Vec<Row> {
    let center_row = content_height / 2;

    if !lens_stack.is_active() {
        // No lens — simple: main buffer centered on cursor
        let base: i64 = main_cursor_line as i64 - center_row as i64;
        return (0..content_height)
            .map(|r| {
                let idx = base + r as i64;
                if idx >= 0 && (idx as usize) < main_lines_len {
                    Row::MainBuffer(idx as usize)
                } else {
                    Row::Blank
                }
            })
            .collect();
    }

    // With lens active: build the interleaved content.
    // The active lens cursor is what we center on.
    // We render: parent lines above → separator → lens lines → separator → parent lines below

    // For now, support single-depth lens (will extend to multi-depth later)
    let layer = lens_stack.active().unwrap();
    let (vis_start, vis_end) = layer.visible_range();

    // Build the full sequence of logical rows
    let mut logical_rows: Vec<Row> = Vec::new();

    // Parent lines above the lens insertion point
    for i in 0..layer.parent_line {
        if i < main_lines_len {
            logical_rows.push(Row::MainBuffer(i));
        }
    }

    // Top separator
    logical_rows.push(Row::Separator(layer.file_name.clone()));

    // Lens visible lines
    for i in vis_start..vis_end {
        logical_rows.push(Row::LensLine(0, i));
    }

    // Bottom separator
    logical_rows.push(Row::Separator(String::new()));

    // Parent lines below the lens insertion point
    for i in layer.parent_line..main_lines_len {
        logical_rows.push(Row::MainBuffer(i));
    }

    // Now we need to center this on the lens cursor.
    // The lens cursor line is at position: (parent_lines_above) + 1(sep) + (cursor - vis_start)
    let cursor_logical_idx = layer.parent_line + 1 + (layer.cursor.line - vis_start);

    // Map logical rows to screen rows, centered on cursor_logical_idx
    let base: i64 = cursor_logical_idx as i64 - center_row as i64;
    (0..content_height)
        .map(|r| {
            let idx = base + r as i64;
            if idx >= 0 && (idx as usize) < logical_rows.len() {
                // Move out of the vec — but we can't move from a Vec by index easily.
                // Instead, clone-ish approach: reconstruct
                match &logical_rows[idx as usize] {
                    Row::MainBuffer(i) => Row::MainBuffer(*i),
                    Row::LensLine(l, i) => Row::LensLine(*l, *i),
                    Row::Separator(s) => Row::Separator(s.clone()),
                    Row::Blank => Row::Blank,
                }
            } else {
                Row::Blank
            }
        })
        .collect()
}

/// Render current editor state to terminal output.
pub fn render_frame(
    lines: &[String],
    cursor: &CursorPosition,
    _viewport: &Viewport,
    width: usize,
    height: usize,
    _lens_buffer: &LensBuffer,
    lens_stack: &LensStack,
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
    let depth_indicator = if lens_stack.is_active() {
        format!(" [depth: {}]", lens_stack.depth())
    } else {
        String::new()
    };
    let top_status = format!("Shards TUI{}", depth_indicator);
    frame.push_str("\x1b[7m");
    frame.push_str(&format!("{:<width$}", top_status, width = width));
    frame.push_str("\x1b[0m\r\n");

    // Determine which cursor to center on
    let active_cursor = if let Some(layer) = lens_stack.active() {
        &layer.cursor
    } else {
        cursor
    };

    // Build the row map
    let rows = build_row_map(lines.len(), cursor.line, lens_stack, content_height);

    // Render each row
    for row in &rows {
        match row {
            Row::MainBuffer(buf_idx) => {
                let is_cursor = !lens_stack.is_active() && *buf_idx == cursor.line;

                // Line number
                let num_str = if is_cursor {
                    format!("{}", buf_idx + 1)
                } else if !lens_stack.is_active() {
                    // Relative to main cursor
                    if *buf_idx < cursor.line {
                        format!("{}", cursor.line - buf_idx)
                    } else {
                        format!("{}", buf_idx - cursor.line)
                    }
                } else {
                    // When lens is active, show absolute for parent lines
                    format!("{}", buf_idx + 1)
                };

                if is_cursor {
                    frame.push_str(&format!("{:<w$} ", num_str, w = line_num_width));
                } else {
                    frame.push_str(&format!("\x1b[2m{:>w$} \x1b[0m", num_str, w = line_num_width));
                }

                let line_str = &lines[*buf_idx];
                let display = if line_str.len() > content_width {
                    &line_str[..content_width]
                } else {
                    line_str.as_str()
                };

                if !lens_stack.is_active() && is_cursor {
                    frame.push_str(&format!("{:<w$}", display, w = content_width));
                } else if lens_stack.is_active() {
                    // Dim parent buffer lines when lens is active
                    frame.push_str(&format!("\x1b[2m{:<w$}\x1b[0m", display, w = content_width));
                } else {
                    frame.push_str(&format!("{:<w$}", display, w = content_width));
                }
            }
            Row::LensLine(_, buf_idx) => {
                let layer = lens_stack.active().unwrap();
                let is_cursor = *buf_idx == layer.cursor.line;

                let num_str = if is_cursor {
                    format!("{}", buf_idx + 1)
                } else if *buf_idx < layer.cursor.line {
                    format!("{}", layer.cursor.line - buf_idx)
                } else {
                    format!("{}", buf_idx - layer.cursor.line)
                };

                if is_cursor {
                    frame.push_str(&format!("{:<w$} ", num_str, w = line_num_width));
                } else {
                    frame.push_str(&format!("{:>w$} ", num_str, w = line_num_width));
                }

                let line_str = &layer.buffer.lines()[*buf_idx];
                let display = if line_str.len() > content_width {
                    &line_str[..content_width]
                } else {
                    line_str.as_str()
                };
                frame.push_str(&format!("{:<w$}", display, w = content_width));
            }
            Row::Separator(label) => {
                let sep_char = '─';
                if label.is_empty() {
                    // Bottom separator: full line
                    let sep: String = std::iter::repeat(sep_char).take(width).collect();
                    frame.push_str(&format!("\x1b[2m{}\x1b[0m", sep));
                } else {
                    // Top separator: line with label right-aligned
                    let label_with_padding = format!(" {} ", label);
                    let sep_len = width.saturating_sub(label_with_padding.len());
                    let sep: String = std::iter::repeat(sep_char).take(sep_len).collect();
                    frame.push_str(&format!("\x1b[2m{}{}\x1b[0m", sep, label_with_padding));
                }
            }
            Row::Blank => {
                frame.push_str(&format!("{:>w$} ", "~", w = line_num_width));
                frame.push_str(&format!("{:<w$}", "", w = content_width));
            }
        }
        frame.push_str("\r\n");
    }

    // Bottom status bar
    let (status_line, status_col, status_total) = if let Some(layer) = lens_stack.active() {
        (layer.cursor.line + 1, layer.cursor.column + 1, layer.buffer.len())
    } else {
        (cursor.line + 1, cursor.column + 1, lines.len())
    };
    let bottom_status = format!(
        "Line {}:{} | {} lines",
        status_line, status_col, status_total,
    );
    frame.push_str("\x1b[7m");
    frame.push_str(&format!("{:<width$}", bottom_status, width = width));
    frame.push_str("\x1b[0m");

    // Position terminal cursor at center_row
    let cursor_screen_row = 2 + center_row;
    let cursor_screen_col = gutter_width + (active_cursor.column + 1).min(content_width);
    frame.push_str(&format!("\x1b[{};{}H", cursor_screen_row, cursor_screen_col));

    frame
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_render_no_lens() {
        let lines: Vec<String> = (0..20).map(|i| format!("Line {}", i)).collect();
        let cursor = CursorPosition { line: 0, column: 0 };
        let viewport = Viewport::new(20);
        let lens_buf = LensBuffer::new();
        let lens_stack = LensStack::new();

        let frame = render_frame(&lines, &cursor, &viewport, 40, 22, &lens_buf, &lens_stack);
        assert!(frame.contains("Line 0"));
        assert!(frame.contains("~")); // Padding above line 0
        assert!(frame.contains("Shards TUI"));
    }

    #[test]
    fn test_render_with_lens() {
        use crate::file::FileBuffer;
        use crate::editor::LensLayer;

        let main_lines: Vec<String> = (0..20).map(|i| format!("main {}", i)).collect();
        let cursor = CursorPosition { line: 10, column: 0 };
        let viewport = Viewport::new(20);
        let lens_buf = LensBuffer::new();

        let mut lens_stack = LensStack::new();
        let fb = FileBuffer::new(
            std::path::PathBuf::from("/tmp/child.rs"),
            (0..15).map(|i| format!("child {}", i)).collect(),
        );
        lens_stack.push(LensLayer::from_file(fb, 10));

        let frame = render_frame(&main_lines, &cursor, &viewport, 60, 22, &lens_buf, &lens_stack);
        // Should contain both parent and child content
        assert!(frame.contains("main"));
        assert!(frame.contains("child"));
        // Should contain separator with filename
        assert!(frame.contains("child.rs"));
        // Should show depth indicator
        assert!(frame.contains("[depth: 1]"));
    }
}
