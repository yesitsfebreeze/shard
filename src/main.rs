use shards_tui::{
    file::FileBuffer,
    ui::{render_frame, InputHandler, KeyCommand, Viewport},
    editor::{LensBuffer, LensStack},
    Editor, Terminal,
};
use std::path::Path;
use std::time::{Duration, Instant};

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 2 {
        eprintln!("Usage: {} <file_path>", args[0]);
        std::process::exit(1);
    }

    let file_path = Path::new(&args[1]);
    let file_buffer = match FileBuffer::load(file_path) {
        Ok(buf) => buf,
        Err(e) => {
            eprintln!("Error loading file: {}", e);
            std::process::exit(1);
        }
    };

    let mut terminal = Terminal::init()?;
    let (mut width, mut height) = terminal.size();

    let mut editor = Editor::new(file_buffer);
    let mut viewport = Viewport::new(height.saturating_sub(2));
    let lens_buffer = LensBuffer::new();
    let mut lens_stack = LensStack::new();

    let mut auto_save_timer: Option<Instant> = None;
    let auto_save_interval = Duration::from_millis(500);

    redraw(&editor, &viewport, &terminal, width, height, &lens_buffer, &lens_stack)?;

    loop {
        let timeout = if editor.dirty {
            auto_save_timer
                .map(|timer| {
                    let elapsed = timer.elapsed();
                    if elapsed >= auto_save_interval { Duration::from_millis(0) }
                    else { auto_save_interval - elapsed }
                })
                .unwrap_or(auto_save_interval)
        } else {
            Duration::from_secs(60)
        };

        if let Some(input) = InputHandler::poll(timeout) {
            let key = input.command;
            let alt_held = input.alt_held;

            match key {
                KeyCommand::CtrlC => {
                    let _ = editor.save();
                    break;
                }

                // --- Navigation ---
                KeyCommand::Up => {
                    if alt_held {
                        // Alt held: move through all content as one continuous buffer
                        let main_lines = editor.buffer().len();
                        let total = lens_stack.total_flat_lines(main_lines);
                        if total > 0 {
                            // Get current position as flat index
                            let current_idx = lens_stack.get_current_flat_index(editor.cursor().line);
                            let new_idx = current_idx.saturating_sub(1);
                            
                            // Get the target buffer and line
                            let (path, line) = lens_stack.get_flat_line(main_lines, new_idx);
                            
                            // Find the lens index (need to do this separately to avoid borrow conflict)
                            let lens_idx = path.and_then(|p| {
                                lens_stack.roots.iter().position(|r| r.buffer.path() == p)
                            });
                            
                            if let Some(idx) = lens_idx {
                                // Target is in a lens - activate it
                                lens_stack.focused_root = Some(idx);
                                if let Some(leaf) = lens_stack.active_leaf_mut() {
                                    leaf.cursor.line = line.min(leaf.buffer.len().saturating_sub(1));
                                    leaf.expand_to_cursor();
                                }
                            } else {
                                // Target is in main buffer - exit lens if active
                                if lens_stack.is_active() {
                                    lens_stack.focus_up();
                                }
                                editor.cursor_mut().line = line;
                                viewport.update(editor.cursor().line, editor.buffer().len());
                            }
                        }
                    } else {
                        // No Alt: move within current buffer only
                        if let Some(leaf) = lens_stack.active_leaf_mut() {
                            let lines = leaf.buffer.lines().to_vec();
                            leaf.cursor.move_up(&lines);
                            leaf.expand_to_cursor();
                        } else {
                            let lines = editor.buffer().lines().to_vec();
                            editor.cursor_mut().move_up(&lines);
                            viewport.update(editor.cursor().line, editor.buffer().len());
                        }
                    }
                    redraw(&editor, &viewport, &terminal, width, height, &lens_buffer, &lens_stack)?;
                }
                KeyCommand::Down => {
                    if alt_held {
                        // Alt held: move through all content as one continuous buffer
                        let main_lines = editor.buffer().len();
                        let total = lens_stack.total_flat_lines(main_lines);
                        if total > 0 {
                            // Get current position as flat index
                            let current_idx = lens_stack.get_current_flat_index(editor.cursor().line);
                            let new_idx = (current_idx + 1).min(total - 1);
                            
                            // Get the target buffer and line
                            let (path, line) = lens_stack.get_flat_line(main_lines, new_idx);
                            
                            // Find the lens index
                            let lens_idx = path.and_then(|p| {
                                lens_stack.roots.iter().position(|r| r.buffer.path() == p)
                            });
                            
                            if let Some(idx) = lens_idx {
                                // Target is in a lens - activate it
                                lens_stack.focused_root = Some(idx);
                                if let Some(leaf) = lens_stack.active_leaf_mut() {
                                    leaf.cursor.line = line.min(leaf.buffer.len().saturating_sub(1));
                                    leaf.expand_to_cursor();
                                }
                            } else {
                                // Target is in main buffer
                                if lens_stack.is_active() {
                                    lens_stack.focus_up();
                                }
                                editor.cursor_mut().line = line;
                                viewport.update(editor.cursor().line, editor.buffer().len());
                            }
                        }
                    } else {
                        // No Alt: move within current buffer only
                        if let Some(leaf) = lens_stack.active_leaf_mut() {
                            let lines = leaf.buffer.lines().to_vec();
                            leaf.cursor.move_down(&lines);
                            leaf.expand_to_cursor();
                        } else {
                            let lines = editor.buffer().lines().to_vec();
                            editor.cursor_mut().move_down(&lines);
                            viewport.update(editor.cursor().line, editor.buffer().len());
                        }
                    }
                    redraw(&editor, &viewport, &terminal, width, height, &lens_buffer, &lens_stack)?;
                }
                KeyCommand::Left => {
                    if let Some(leaf) = lens_stack.active_leaf_mut() {
                        leaf.cursor.move_left();
                    } else {
                        editor.cursor_mut().move_left();
                    }
                    redraw(&editor, &viewport, &terminal, width, height, &lens_buffer, &lens_stack)?;
                }
                KeyCommand::Right => {
                    if let Some(leaf) = lens_stack.active_leaf_mut() {
                        let lines = leaf.buffer.lines().to_vec();
                        leaf.cursor.move_right(&lines);
                    } else {
                        let lines = editor.buffer().lines().to_vec();
                        editor.cursor_mut().move_right(&lines);
                    }
                    redraw(&editor, &viewport, &terminal, width, height, &lens_buffer, &lens_stack)?;
                }

                // --- Text editing ---
                KeyCommand::Char(c) => {
                    if let Some(leaf) = lens_stack.active_leaf_mut() {
                        let line = leaf.cursor.line;
                        let col = leaf.cursor.column;
                        if let Ok(()) = leaf.buffer.insert_char(line, col, c) {
                            let lines = leaf.buffer.lines().to_vec();
                            leaf.cursor.move_right(&lines);
                            leaf.dirty = true;
                            leaf.expand_to_cursor();
                        }
                    } else {
                        let line = editor.cursor().line;
                        let col = editor.cursor().column;
                        if let Ok(()) = editor.buffer_mut().insert_char(line, col, c) {
                            let lines = editor.buffer().lines().to_vec();
                            editor.cursor_mut().move_right(&lines);
                        }
                        editor.set_dirty();
                        auto_save_timer = Some(Instant::now());
                    }
                    redraw(&editor, &viewport, &terminal, width, height, &lens_buffer, &lens_stack)?;
                }
                KeyCommand::Backspace => {
                    if let Some(leaf) = lens_stack.active_leaf_mut() {
                        if leaf.cursor.column > 0 {
                            leaf.cursor.move_left();
                            let line = leaf.cursor.line;
                            let col = leaf.cursor.column;
                            let _ = leaf.buffer.delete_char(line, col);
                            leaf.dirty = true;
                        }
                    } else {
                        if editor.cursor().column > 0 {
                            editor.cursor_mut().move_left();
                            let line = editor.cursor().line;
                            let col = editor.cursor().column;
                            let _ = editor.buffer_mut().delete_char(line, col);
                        }
                        editor.set_dirty();
                        auto_save_timer = Some(Instant::now());
                    }
                    redraw(&editor, &viewport, &terminal, width, height, &lens_buffer, &lens_stack)?;
                }
                KeyCommand::Delete => {
                    if let Some(leaf) = lens_stack.active_leaf_mut() {
                        let line = leaf.cursor.line;
                        let col = leaf.cursor.column;
                        let _ = leaf.buffer.delete_char(line, col);
                        leaf.dirty = true;
                    } else {
                        let line = editor.cursor().line;
                        let col = editor.cursor().column;
                        let _ = editor.buffer_mut().delete_char(line, col);
                        editor.set_dirty();
                        auto_save_timer = Some(Instant::now());
                    }
                    redraw(&editor, &viewport, &terminal, width, height, &lens_buffer, &lens_stack)?;
                }

                // --- Lens: open file (recursively) ---
                KeyCommand::CtrlO => {
                    // Pick the file to open: second arg, or default to Cargo.toml
                    let test_path = if args.len() > 2 {
                        Path::new(&args[2])
                    } else {
                        Path::new("Cargo.toml")
                    };

                    if let Ok(fb) = FileBuffer::load(test_path) {
                        let parent_line = if let Some(leaf) = lens_stack.active_leaf() {
                            leaf.cursor.line
                        } else {
                            editor.cursor().line
                        };
                        // open_lens handles recursive nesting automatically:
                        // if inside a lens, opens as child of active leaf;
                        // if at root, opens as root-level lens
                        lens_stack.open_lens(fb, parent_line);
                    }
                    redraw(&editor, &viewport, &terminal, width, height, &lens_buffer, &lens_stack)?;
                }

                KeyCommand::Escape => {
                    if lens_stack.is_active() {
                        lens_stack.focus_up();
                        redraw(&editor, &viewport, &terminal, width, height, &lens_buffer, &lens_stack)?;
                    }
                }

                KeyCommand::Enter => {
                    // Try to focus down into a lens at current position
                    let current_line = if let Some(leaf) = lens_stack.active_leaf() {
                        leaf.cursor.line
                    } else {
                        editor.cursor().line
                    };
                    if lens_stack.focus_down(current_line) {
                        redraw(&editor, &viewport, &terminal, width, height, &lens_buffer, &lens_stack)?;
                    }
                }

                _ => {}
            }
        } else {
            if let Some(timer) = auto_save_timer {
                if timer.elapsed() >= auto_save_interval && editor.dirty {
                    let _ = editor.save();
                    auto_save_timer = None;
                }
            }
        }

        if let Ok(new_size) = crossterm::terminal::size() {
            let (nw, nh) = (new_size.0 as usize, new_size.1 as usize);
            if (nw, nh) != (width, height) {
                terminal.update_size()?;
                width = nw;
                height = nh;
                viewport.set_height(height.saturating_sub(2));
                redraw(&editor, &viewport, &terminal, width, height, &lens_buffer, &lens_stack)?;
            }
        }
    }

    terminal.cleanup()?;
    Ok(())
}

fn redraw(
    editor: &Editor,
    viewport: &Viewport,
    terminal: &Terminal,
    width: usize,
    height: usize,
    lens_buffer: &LensBuffer,
    lens_stack: &LensStack,
) -> std::io::Result<()> {
    let frame = render_frame(
        editor.buffer().lines(),
        editor.cursor(),
        viewport,
        width,
        height,
        lens_buffer,
        lens_stack,
    );
    terminal.draw(&frame)
}
