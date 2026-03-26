//! Terminal UI module - handles rendering, input, and terminal management

pub mod input;
pub mod renderer;
pub mod viewport;

use crossterm::{
    execute,
    terminal::{disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen},
};
use std::io::{stdout, Write};

/// Terminal management and drawing
pub struct Terminal {
    width: usize,
    height: usize,
}

impl Terminal {
    /// Initialize terminal: enable raw mode, alternate screen, mouse tracking
    pub fn init() -> std::io::Result<Self> {
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
    pub fn update_size(&mut self) -> std::io::Result<()> {
        let (width, height) = crossterm::terminal::size()?;
        self.width = width as usize;
        self.height = height as usize;
        Ok(())
    }

    /// Write frame buffer to terminal
    pub fn draw(&self, frame: &str) -> std::io::Result<()> {
        use crossterm::cursor::MoveTo;
        use crossterm::terminal::Clear;
        use crossterm::terminal::ClearType;

        let mut stdout = stdout();
        // Clear entire screen and move to top-left
        execute!(stdout, Clear(ClearType::All), MoveTo(0, 0))?;
        // Write frame content
        stdout.write_all(frame.as_bytes())?;
        stdout.flush()?;
        Ok(())
    }

    /// Cleanup: disable raw mode, restore normal screen
    pub fn cleanup(&self) -> std::io::Result<()> {
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

pub use input::{InputHandler, KeyCommand};
pub use renderer::render_frame;
pub use viewport::Viewport;
