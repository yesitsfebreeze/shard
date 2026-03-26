use shards_tui::{
    file::FileBuffer,
    ui::{render_frame, InputHandler, KeyCommand, Viewport},
    editor::{LensBuffer, LensLayer, LensStack},
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
    let lens_buffer = LensBuffer::new(); // Legacy, kept for API compat
    let mut lens_stack = LensStack::new();
    // Keep last-popped lens so Alt+Down can re-open it
    let mut last_popped_lens: Option<LensLayer> = None;

    let mut auto_save_timer: Option<Instant> = None;
    let auto_save_interval = Duration::from_millis(500);

    redraw(&editor, &viewport, &terminal, width, height, &lens_buffer, &lens_stack)?;

    loop {
        let timeout = if editor.dirty {
            auto_save_timer
                .map(|timer| {
                    let elapsed = timer.elapsed();
                    if elapsed >= auto_save_interval {
                        Duration::from_millis(0)
                    } else {
                        auto_save_interval - elapsed
                    }
                })
                .unwrap_or(auto_save_interval)
        } else {
            Duration::from_secs(60)
        };

        if let Some(key) = InputHandler::poll(timeout) {
            match key {
                KeyCommand::CtrlC => {
                    let _ = editor.save();
                    break;
                }

                // --- Navigation ---
                KeyCommand::Up => {
                    if let Some(layer) = lens_stack.active_mut() {
                        let lines = layer.buffer.lines().to_vec();
                        layer.cursor.move_up(&lines);
                        layer.expand_to_cursor();
                    } else {
                        let lines = editor.buffer().lines().to_vec();
                        editor.cursor_mut().move_up(&lines);
                        viewport.update(editor.cursor().line, editor.buffer().len());
                    }
                    redraw(&editor, &viewport, &terminal, width, height, &lens_buffer, &lens_stack)?;
                }
                KeyCommand::Down => {
                    if let Some(layer) = lens_stack.active_mut() {
                        let lines = layer.buffer.lines().to_vec();
                        layer.cursor.move_down(&lines);
                        layer.expand_to_cursor();
                    } else {
                        let lines = editor.buffer().lines().to_vec();
                        editor.cursor_mut().move_down(&lines);
                        viewport.update(editor.cursor().line, editor.buffer().len());
                    }
                    redraw(&editor, &viewport, &terminal, width, height, &lens_buffer, &lens_stack)?;
                }
                KeyCommand::Left => {
                    if let Some(layer) = lens_stack.active_mut() {
                        layer.cursor.move_left();
                    } else {
                        editor.cursor_mut().move_left();
                    }
                    redraw(&editor, &viewport, &terminal, width, height, &lens_buffer, &lens_stack)?;
                }
                KeyCommand::Right => {
                    if let Some(layer) = lens_stack.active_mut() {
                        let lines = layer.buffer.lines().to_vec();
                        layer.cursor.move_right(&lines);
                    } else {
                        let lines = editor.buffer().lines().to_vec();
                        editor.cursor_mut().move_right(&lines);
                    }
                    redraw(&editor, &viewport, &terminal, width, height, &lens_buffer, &lens_stack)?;
                }

                // --- Text editing ---
                KeyCommand::Char(c) => {
                    if let Some(layer) = lens_stack.active_mut() {
                        let line = layer.cursor.line;
                        let col = layer.cursor.column;
                        if let Ok(()) = layer.buffer.insert_char(line, col, c) {
                            let lines = layer.buffer.lines().to_vec();
                            layer.cursor.move_right(&lines);
                            layer.dirty = true;
                            layer.expand_to_cursor();
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
                    if let Some(layer) = lens_stack.active_mut() {
                        if layer.cursor.column > 0 {
                            layer.cursor.move_left();
                            let line = layer.cursor.line;
                            let col = layer.cursor.column;
                            let _ = layer.buffer.delete_char(line, col);
                            layer.dirty = true;
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
                    if let Some(layer) = lens_stack.active_mut() {
                        let line = layer.cursor.line;
                        let col = layer.cursor.column;
                        let _ = layer.buffer.delete_char(line, col);
                        layer.dirty = true;
                    } else {
                        let line = editor.cursor().line;
                        let col = editor.cursor().column;
                        let _ = editor.buffer_mut().delete_char(line, col);
                        editor.set_dirty();
                        auto_save_timer = Some(Instant::now());
                    }
                    redraw(&editor, &viewport, &terminal, width, height, &lens_buffer, &lens_stack)?;
                }

                // --- Lens: open file ---
                KeyCommand::CtrlO => {
                    // For now, open a hardcoded second file for testing.
                    // TODO: replace with file picker
                    let test_path = if args.len() > 2 {
                        Path::new(&args[2])
                    } else {
                        // Try to open Cargo.toml as a demo
                        Path::new("Cargo.toml")
                    };

                    if let Ok(fb) = FileBuffer::load(test_path) {
                        let parent_line = if let Some(layer) = lens_stack.active() {
                            layer.cursor.line
                        } else {
                            editor.cursor().line
                        };
                        lens_stack.push(LensLayer::from_file(fb, parent_line));
                        last_popped_lens = None;
                    }
                    redraw(&editor, &viewport, &terminal, width, height, &lens_buffer, &lens_stack)?;
                }

                // --- Lens stack navigation ---
                KeyCommand::AltUp => {
                    // Pop up one lens level
                    if let Some(popped) = lens_stack.pop() {
                        last_popped_lens = Some(popped);
                    }
                    redraw(&editor, &viewport, &terminal, width, height, &lens_buffer, &lens_stack)?;
                }
                KeyCommand::AltDown => {
                    // Re-open last popped lens
                    if let Some(layer) = last_popped_lens.take() {
                        lens_stack.push(layer);
                    }
                    redraw(&editor, &viewport, &terminal, width, height, &lens_buffer, &lens_stack)?;
                }

                KeyCommand::Escape => {
                    // Close active lens
                    if let Some(popped) = lens_stack.pop() {
                        last_popped_lens = Some(popped);
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
            let (new_width, new_height) = (new_size.0 as usize, new_size.1 as usize);
            if (new_width, new_height) != (width, height) {
                terminal.update_size()?;
                width = new_width;
                height = new_height;
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
