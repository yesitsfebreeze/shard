use shards_tui::{Terminal, Editor, ui::{InputHandler, KeyCommand, Viewport, render_frame}, file::FileBuffer};
use std::time::{Duration, Instant};
use std::path::Path;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    // Parse command-line arguments
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 2 {
        eprintln!("Usage: {} <file_path>", args[0]);
        std::process::exit(1);
    }

    let file_path = Path::new(&args[1]);

    // Load file
    let file_buffer = match FileBuffer::load(file_path) {
        Ok(buf) => buf,
        Err(e) => {
            eprintln!("Error loading file: {}", e);
            std::process::exit(1);
        }
    };

    // Initialize terminal
    let mut terminal = Terminal::init()?;
    let (width, height) = terminal.size();

    // Create editor
    let mut editor = Editor::new(file_buffer);
    let mut viewport = Viewport::new(height.saturating_sub(2)); // Reserve 2 lines for status bars

    // Main event loop
    let frame_time = Duration::from_nanos(16_666_667); // 60 FPS
    let mut last_render = Instant::now();
    let mut auto_save_timer: Option<Instant> = None;
    let auto_save_interval = Duration::from_millis(500);

    loop {
        // Poll for input with timeout
        let remaining = frame_time.saturating_sub(last_render.elapsed());
        if let Some(key) = InputHandler::poll(remaining) {
            match key {
                KeyCommand::CtrlC | KeyCommand::Escape => {
                    // Save before exit
                    let _ = editor.save();
                    break;
                }
                KeyCommand::Up => {
                    editor.cursor_mut().move_up(editor.buffer().lines());
                    viewport.update(editor.cursor().line, editor.buffer().len());
                    editor.set_dirty();
                    auto_save_timer = Some(Instant::now());
                }
                KeyCommand::Down => {
                    editor.cursor_mut().move_down(editor.buffer().lines());
                    viewport.update(editor.cursor().line, editor.buffer().len());
                    editor.set_dirty();
                    auto_save_timer = Some(Instant::now());
                }
                KeyCommand::Left => {
                    editor.cursor_mut().move_left();
                    editor.set_dirty();
                    auto_save_timer = Some(Instant::now());
                }
                KeyCommand::Right => {
                    editor.cursor_mut().move_right(editor.buffer().lines());
                    editor.set_dirty();
                    auto_save_timer = Some(Instant::now());
                }
                KeyCommand::Char(c) => {
                    let line = editor.cursor().line;
                    let col = editor.cursor().column;
                    if let Ok(()) = editor.buffer_mut().insert_char(line, col, c) {
                        editor.cursor_mut().move_right(editor.buffer().lines());
                    }
                    editor.set_dirty();
                    auto_save_timer = Some(Instant::now());
                }
                KeyCommand::Backspace => {
                    if editor.cursor().column > 0 {
                        editor.cursor_mut().move_left();
                        let line = editor.cursor().line;
                        let col = editor.cursor().column;
                        let _ = editor.buffer_mut().delete_char(line, col);
                    }
                    editor.set_dirty();
                    auto_save_timer = Some(Instant::now());
                }
                KeyCommand::Delete => {
                    let line = editor.cursor().line;
                    let col = editor.cursor().column;
                    let _ = editor.buffer_mut().delete_char(line, col);
                    editor.set_dirty();
                    auto_save_timer = Some(Instant::now());
                }
                _ => {}
            }
        }

        // Check for terminal resize
        if let Ok(new_size) = crossterm::terminal::size() {
            if (new_size.0 as usize, new_size.1 as usize) != (width, height) {
                terminal.update_size()?;
                let (new_width, new_height) = terminal.size();
                viewport.set_height(new_height.saturating_sub(2));
            }
        }

        // Auto-save timer
        if let Some(timer) = auto_save_timer {
            if timer.elapsed() >= auto_save_interval && editor.dirty {
                let _ = editor.save();
                auto_save_timer = None;
            }
        }

        // Render frame if enough time has passed or state changed
        if last_render.elapsed() >= frame_time {
            let frame = render_frame(
                editor.buffer().lines(),
                editor.cursor(),
                &viewport,
                width,
                height.saturating_sub(2),
            );
            terminal.draw(&frame)?;
            last_render = Instant::now();
        }
    }

    terminal.cleanup()?;
    Ok(())
}
