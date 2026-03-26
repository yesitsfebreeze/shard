use shards_tui::{
    file::FileBuffer,
    ui::{render_frame, InputHandler, KeyCommand, Viewport},
    editor::LensBuffer,
    Editor, Terminal,
};
use std::path::Path;
use std::time::{Duration, Instant};

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
    let (mut width, mut height) = terminal.size();

    // Create editor
    let mut editor = Editor::new(file_buffer);
    let mut viewport = Viewport::new(height.saturating_sub(2));
    let mut lens = LensBuffer::new();

    // Auto-save timer
    let mut auto_save_timer: Option<Instant> = None;
    let auto_save_interval = Duration::from_millis(500);

    // Initial render
    redraw(&editor, &viewport, &terminal, width, height, &lens)?;

    // Event-driven main loop
    loop {
        // Poll for input with timeout for auto-save timer
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
            Duration::from_secs(60) // Long timeout if not dirty
        };

        if let Some(key) = InputHandler::poll(timeout) {
            match key {
                KeyCommand::CtrlC => {
                    // Save before exit
                    let _ = editor.save();
                    break;
                }
                KeyCommand::Up => {
                    let lines = editor.buffer().lines().to_vec();
                    editor.cursor_mut().move_up(&lines);
                    viewport.update(editor.cursor().line, editor.buffer().len());
                    editor.set_dirty();
                    auto_save_timer = Some(Instant::now());
                    redraw(&editor, &viewport, &terminal, width, height, &lens)?;
                }
                KeyCommand::Down => {
                    let lines = editor.buffer().lines().to_vec();
                    editor.cursor_mut().move_down(&lines);
                    viewport.update(editor.cursor().line, editor.buffer().len());
                    editor.set_dirty();
                    auto_save_timer = Some(Instant::now());
                    redraw(&editor, &viewport, &terminal, width, height, &lens)?;
                }
                KeyCommand::Left => {
                    editor.cursor_mut().move_left();
                    editor.set_dirty();
                    auto_save_timer = Some(Instant::now());
                    redraw(&editor, &viewport, &terminal, width, height, &lens)?;
                }
                KeyCommand::Right => {
                    let lines = editor.buffer().lines().to_vec();
                    editor.cursor_mut().move_right(&lines);
                    editor.set_dirty();
                    auto_save_timer = Some(Instant::now());
                    redraw(&editor, &viewport, &terminal, width, height, &lens)?;
                }
                KeyCommand::Char(c) => {
                    let line = editor.cursor().line;
                    let col = editor.cursor().column;
                    if let Ok(()) = editor.buffer_mut().insert_char(line, col, c) {
                        let lines = editor.buffer().lines().to_vec();
                        editor.cursor_mut().move_right(&lines);
                    }
                    editor.set_dirty();
                    auto_save_timer = Some(Instant::now());
                    redraw(&editor, &viewport, &terminal, width, height, &lens)?;
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
                    redraw(&editor, &viewport, &terminal, width, height, &lens)?;
                }
                KeyCommand::Delete => {
                    let line = editor.cursor().line;
                    let col = editor.cursor().column;
                    let _ = editor.buffer_mut().delete_char(line, col);
                    editor.set_dirty();
                    auto_save_timer = Some(Instant::now());
                    redraw(&editor, &viewport, &terminal, width, height, &lens)?;
                }
                KeyCommand::CtrlF => {
                    // Toggle search lens
                    if lens.is_visible() {
                        lens.hide();
                    } else {
                        lens.show_search();
                    }
                    redraw(&editor, &viewport, &terminal, width, height, &lens)?;
                }
                _ => {}
            }
        } else {
            // Timeout fired - check if auto-save needed
            if let Some(timer) = auto_save_timer {
                if timer.elapsed() >= auto_save_interval && editor.dirty {
                    let _ = editor.save();
                    auto_save_timer = None;
                }
            }
        }

        // Check for terminal resize (happens outside of input events)
        if let Ok(new_size) = crossterm::terminal::size() {
            let (new_width, new_height) = (new_size.0 as usize, new_size.1 as usize);
            if (new_width, new_height) != (width, height) {
                terminal.update_size()?;
                width = new_width;
                height = new_height;
                viewport.set_height(height.saturating_sub(2));
                redraw(&editor, &viewport, &terminal, width, height, &lens)?;
            }
        }
    }

    terminal.cleanup()?;
    Ok(())
}

/// Render the current editor state to terminal
fn redraw(
    editor: &Editor,
    viewport: &Viewport,
    terminal: &Terminal,
    width: usize,
    height: usize,
    lens: &LensBuffer,
) -> std::io::Result<()> {
    let frame = render_frame(
        editor.buffer().lines(),
        editor.cursor(),
        viewport,
        width,
        height,
        lens,
    );
    terminal.draw(&frame)
}
