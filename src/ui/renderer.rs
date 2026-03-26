//! Rendering - builds terminal output with cursor ALWAYS at vertical center
//!
//! Renders a recursive lens tree. Each buffer can have lenses open at various
//! lines. The focused lens path determines what's centered on screen.
//! Parent buffer lines are dimmed; the active lens is rendered normally.

use super::viewport::Viewport;
use crate::editor::{CursorPosition, LensBuffer, LensLayer, LensStack};

/// A renderable row
#[derive(Clone)]
enum Row {
    /// Buffer line: (depth, buffer_line_index, is_in_focused_buffer)
    Line(usize, usize, bool),
    /// File header with path and line range: (depth, path, start_line, end_line)
    FileHeader(usize, String, usize, usize),
    /// Blank padding
    Blank,
}

/// Get full file path from a lens layer
fn get_full_path(layer: &LensLayer) -> String {
    layer.buffer.path().display().to_string()
}

/// Recursively build logical rows for a buffer that may contain child lenses.
/// `depth` tracks nesting level. `is_focused_path` means this buffer or one
/// of its descendants holds the active cursor.
fn build_rows_for_layer(
    layer: &LensLayer,
    depth: usize,
    is_focused_path: bool,
) -> (Vec<Row>, Option<usize>) {
    let (vis_start, vis_end) = layer.visible_range();
    let mut rows = Vec::new();
    let mut cursor_row = None;

    // Collect children that are visible within this layer's window
    let visible_children: Vec<(usize, &LensLayer)> = layer
        .children
        .iter()
        .enumerate()
        .filter(|(_, c)| c.parent_line >= vis_start && c.parent_line < vis_end)
        .collect();

    let mut line = vis_start;
    for (child_idx, child) in &visible_children {
        // Emit buffer lines up to this child's insertion point
        while line < child.parent_line && line < vis_end {
            let is_cursor =
                is_focused_path && !layer.has_focused_child() && line == layer.cursor.line;
            if is_cursor {
                cursor_row = Some(rows.len());
            }
            rows.push(Row::Line(
                depth,
                line,
                is_focused_path && !layer.has_focused_child(),
            ));
            line += 1;
        }

        // Render the child lens
        let child_is_focused = layer.focused_child == Some(*child_idx);
        let full_path = get_full_path(child);
        let start_line = child.window_top + 1;
        let end_line = child.window_bottom + 1;
        rows.push(Row::FileHeader(depth + 1, full_path, start_line, end_line));
        let (child_rows, child_cursor_row) =
            build_rows_for_layer(child, depth + 1, is_focused_path && child_is_focused);
        if let Some(cr) = child_cursor_row {
            cursor_row = Some(rows.len() + cr);
        }
        rows.extend(child_rows);
    }

    // Emit remaining lines after last child
    while line < vis_end {
        let is_cursor = is_focused_path && !layer.has_focused_child() && line == layer.cursor.line;
        if is_cursor {
            cursor_row = Some(rows.len());
        }
        rows.push(Row::Line(
            depth,
            line,
            is_focused_path && !layer.has_focused_child(),
        ));
        line += 1;
    }

    (rows, cursor_row)
}

/// Build the full row map from the main buffer + lens tree
fn build_row_map(
    main_lines_len: usize,
    main_cursor_line: usize,
    lens_stack: &LensStack,
    content_height: usize,
) -> (Vec<Row>, usize) {
    let center_row = content_height / 2;

    // Build all logical rows
    let mut logical_rows: Vec<Row> = Vec::new();
    let mut cursor_logical_idx: Option<usize> = None;

    let no_lens_focused = !lens_stack.is_active();

    // Walk main buffer lines, interleaving root lenses
    let mut main_line = 0;
    let root_lenses: Vec<(usize, &LensLayer)> =
        lens_stack.root_layers().iter().enumerate().collect();

    for (root_idx, root_lens) in &root_lenses {
        // Emit main buffer lines up to this lens's insertion point
        while main_line < root_lens.parent_line && main_line < main_lines_len {
            if no_lens_focused && main_line == main_cursor_line {
                cursor_logical_idx = Some(logical_rows.len());
            }
            logical_rows.push(Row::Line(0, main_line, no_lens_focused));
            main_line += 1;
        }

        // Render this root lens
        let root_is_focused = lens_stack.focused_root == Some(*root_idx);
        let full_path = get_full_path(root_lens);
        let start_line = root_lens.window_top + 1;
        let end_line = root_lens.window_bottom + 1;
        logical_rows.push(Row::FileHeader(0, full_path, start_line, end_line));
        let (child_rows, child_cursor) = build_rows_for_layer(root_lens, 1, root_is_focused);
        if let Some(cr) = child_cursor {
            cursor_logical_idx = Some(logical_rows.len() + cr);
        }
        logical_rows.extend(child_rows);
    }

    // Remaining main buffer lines after all lenses
    while main_line < main_lines_len {
        if no_lens_focused && main_line == main_cursor_line {
            cursor_logical_idx = Some(logical_rows.len());
        }
        logical_rows.push(Row::Line(0, main_line, no_lens_focused));
        main_line += 1;
    }

    // Default cursor to center if not found
    let cursor_idx = cursor_logical_idx.unwrap_or(0);

    // Window into logical rows, centered on cursor
    let base: i64 = cursor_idx as i64 - center_row as i64;
    let screen_rows: Vec<Row> = (0..content_height)
        .map(|r| {
            let idx = base + r as i64;
            if idx >= 0 && (idx as usize) < logical_rows.len() {
                logical_rows[idx as usize].clone()
            } else {
                Row::Blank
            }
        })
        .collect();

    (screen_rows, center_row)
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
    frame.push_str("\x1b[2J\x1b[H");

    let content_height = height.saturating_sub(2);
    let center_row = content_height / 2;

    // Line number gutter
    let line_num_width = ((lines.len() as f64).log10().ceil() as usize).max(3);
    let gutter_width = line_num_width + 1;
    let content_width = width.saturating_sub(gutter_width);

    // Top status bar
    let depth = lens_stack.depth();
    let depth_str = if depth > 0 {
        format!(" [depth: {}]", depth)
    } else {
        String::new()
    };
    let file_str = if let Some(leaf) = lens_stack.active_leaf() {
        format!(" — {}", leaf.file_name)
    } else {
        String::new()
    };
    let top_status = format!("Shards TUI{}{}", file_str, depth_str);
    frame.push_str("\x1b[7m");
    frame.push_str(&format!("{:<width$}", top_status, width = width));
    frame.push_str("\x1b[0m\r\n");

    // Build rows
    let (rows, _) = build_row_map(lines.len(), cursor.line, lens_stack, content_height);

    // Determine active cursor for column positioning
    let active_cursor = lens_stack
        .active_leaf()
        .map(|l| &l.cursor)
        .unwrap_or(cursor);

    // Render
    for row in &rows {
        match row {
            Row::Line(depth_level, buf_idx, is_active_buf) => {
                // Get the right buffer and cursor for this depth
                let (line_str, line_cursor, _total_lines) = if *depth_level == 0 {
                    (lines[*buf_idx].as_str(), cursor, lines.len())
                } else {
                    // Find the lens layer that owns this line — for now use active leaf
                    // since that's what's focused
                    if let Some(leaf) = lens_stack.active_leaf() {
                        (
                            leaf.buffer.lines()[*buf_idx].as_str(),
                            &leaf.cursor,
                            leaf.buffer.len(),
                        )
                    } else {
                        (
                            lines.get(*buf_idx).map(|s| s.as_str()).unwrap_or(""),
                            cursor,
                            lines.len(),
                        )
                    }
                };

                let is_cursor_line = *is_active_buf && *buf_idx == line_cursor.line;

                // Line number
                let num = if is_cursor_line {
                    format!("{}", buf_idx + 1)
                } else if *is_active_buf {
                    let cl = line_cursor.line;
                    if *buf_idx < cl {
                        format!("{}", cl - buf_idx)
                    } else {
                        format!("{}", buf_idx - cl)
                    }
                } else {
                    format!("{}", buf_idx + 1)
                };

                let dim = !is_active_buf;
                if dim {
                    frame.push_str("\x1b[2m");
                }

                if is_cursor_line {
                    frame.push_str(&format!("{:<w$} ", num, w = line_num_width));
                } else {
                    frame.push_str(&format!("{:>w$} ", num, w = line_num_width));
                }

                let display = if line_str.len() > content_width {
                    &line_str[..content_width]
                } else {
                    line_str
                };
                frame.push_str(&format!("{:<w$}", display, w = content_width));

                if dim {
                    frame.push_str("\x1b[0m");
                }
            }
            Row::FileHeader(_depth, path, start_line, end_line) => {
                let header = format!("{} ({}:{})", path, start_line, end_line);
                frame.push_str("\x1b[2m");
                frame.push_str(&format!("{:<width$}", header, width = width));
                frame.push_str("\x1b[0m");
            }
            Row::Blank => {
                frame.push_str(&format!("{:>w$} ", "~", w = line_num_width));
                frame.push_str(&format!("{:<w$}", "", w = content_width));
            }
        }
        frame.push_str("\r\n");
    }

    // Bottom status bar
    let (sl, sc, st) = if let Some(leaf) = lens_stack.active_leaf() {
        (
            leaf.cursor.line + 1,
            leaf.cursor.column + 1,
            leaf.buffer.len(),
        )
    } else {
        (cursor.line + 1, cursor.column + 1, lines.len())
    };
    let bottom_status = format!("Line {}:{} | {} lines", sl, sc, st);
    frame.push_str("\x1b[7m");
    frame.push_str(&format!("{:<width$}", bottom_status, width = width));
    frame.push_str("\x1b[0m");

    // Cursor position
    let cursor_screen_row = 2 + center_row;
    let cursor_screen_col = gutter_width + (active_cursor.column + 1).min(content_width);

    frame.push_str(&format!(
        "\x1b[{};{}H",
        cursor_screen_row, cursor_screen_col
    ));

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
        let lb = LensBuffer::new();
        let ls = LensStack::new();

        let frame = render_frame(&lines, &cursor, &viewport, 40, 22, &lb, &ls);
        assert!(frame.contains("Line 0"));
        assert!(frame.contains("~"));
    }

    #[test]
    fn test_render_with_lens() {
        use crate::file::FileBuffer;

        let main_lines: Vec<String> = (0..20).map(|i| format!("main {}", i)).collect();
        let cursor = CursorPosition {
            line: 10,
            column: 0,
        };
        let viewport = Viewport::new(20);
        let lb = LensBuffer::new();
        let mut ls = LensStack::new();

        let fb = FileBuffer::new(
            std::path::PathBuf::from("/tmp/child.rs"),
            (0..15).map(|i| format!("child {}", i)).collect(),
        );
        ls.open_lens(fb, 10);

        let frame = render_frame(&main_lines, &cursor, &viewport, 60, 22, &lb, &ls, None);
        assert!(frame.contains("main"));
        assert!(frame.contains("child"));
        assert!(frame.contains("child.rs"));
        assert!(frame.contains("[depth: 1]"));
    }
}
