//! Terminal UI module - handles rendering, input, and terminal management

pub mod renderer;
pub mod viewport;
pub mod input;

use crossterm::{
    terminal::{enable_raw_mode, disable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen},
    execute,
};
use std::io::stdout;

/// Terminal management and drawing
pub struct Terminal {
    width: usize,
    height: usize,
}

impl Terminal {
    /// Initialize terminal: enable raw mode, alternate screen, mouse tracking
    pub fn init() -> crossterm::Result<Self> {
        enable_raw_mode()?;
        let mut stdout = stdout();
        execute!(stdout, EnterAlternateScreen)?;

        let (width, height) = crossterm::terminal::size()?;
        Ok(Terminal {
            width: width as usize,
            height: height as usize,
        })
    }

    /// Get current terminal dimensions
    pub fn size(&self) -> (usize, usize) {
        (self.width, self.height)
    }

    /// Update terminal dimensions (called on SIGWINCH/resize event)
    pub fn update_size(&mut self) -> crossterm::Result<()> {
        let (width, height) = crossterm::terminal::size()?;
        self.width = width as usize;
        self.height = height as usize;
        Ok(())
    }

    /// Write frame buffer to terminal
    pub fn draw(&self, frame: &str) -> crossterm::Result<()> {
        use crossterm::cursor::MoveTo;
        let mut stdout = stdout();
        execute!(stdout, MoveTo(0, 0))?;
        print!("{}", frame);
        stdout.flush().ok();
        Ok(())
    }

    /// Cleanup: disable raw mode, restore normal screen
    pub fn cleanup(&self) -> crossterm::Result<()> {
        let mut stdout = stdout();
        execute!(stdout, LeaveAlternateScreen)?;
        disable_raw_mode()?;
        Ok(())
    }
}

impl Drop for Terminal {
    fn drop(&mut self) {
        let _ = self.cleanup();
    }
}

pub use renderer::render_frame;
pub use viewport::Viewport;
pub use input::{InputHandler, KeyCommand};
