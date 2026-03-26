//! Input handling - parses keyboard events

use crossterm::event::{self, Event, KeyCode, KeyEvent, KeyModifiers};

/// Represents a user input command
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KeyCommand {
    Up,
    Down,
    Left,
    Right,
    Char(char),
    Backspace,
    Delete,
    Enter,
    Tab,
    Escape,
    CtrlC,
    CtrlN, // Next steps
    CtrlF, // Open file
    Unknown,
}

/// Handles keyboard input events
pub struct InputHandler;

impl InputHandler {
    /// Poll for a keyboard event with timeout
    pub fn poll(timeout: std::time::Duration) -> Option<KeyCommand> {
        if event::poll(timeout).ok()? {
            match event::read().ok()? {
                Event::Key(key) => Some(Self::parse_key(key)),
                Event::Resize(_, _) => Some(KeyCommand::Unknown), // Handle resize elsewhere
                _ => None,
            }
        } else {
            None
        }
    }

    /// Parse a single key event to KeyCommand
    fn parse_key(key: KeyEvent) -> KeyCommand {
        match key.code {
            KeyCode::Up => KeyCommand::Up,
            KeyCode::Down => KeyCommand::Down,
            KeyCode::Left => KeyCommand::Left,
            KeyCode::Right => KeyCommand::Right,
            KeyCode::Backspace => KeyCommand::Backspace,
            KeyCode::Delete => KeyCommand::Delete,
            KeyCode::Enter => KeyCommand::Enter,
            KeyCode::Tab => KeyCommand::Tab,
            KeyCode::Esc => KeyCommand::Escape,
            KeyCode::Char('c') if key.modifiers.contains(KeyModifiers::CONTROL) => {
                KeyCommand::CtrlC
            }
            KeyCode::Char('n') if key.modifiers.contains(KeyModifiers::CONTROL) => {
                KeyCommand::CtrlN
            }
            KeyCode::Char('f') if key.modifiers.contains(KeyModifiers::CONTROL) => {
                KeyCommand::CtrlF
            }
            KeyCode::Char(c) => KeyCommand::Char(c),
            _ => KeyCommand::Unknown,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_char() {
        let key = KeyEvent::new(KeyCode::Char('a'), KeyModifiers::empty());
        assert_eq!(InputHandler::parse_key(key), KeyCommand::Char('a'));
    }

    #[test]
    fn test_parse_arrow() {
        let key = KeyEvent::new(KeyCode::Up, KeyModifiers::empty());
        assert_eq!(InputHandler::parse_key(key), KeyCommand::Up);
    }

    #[test]
    fn test_parse_ctrl_c() {
        let key = KeyEvent::new(KeyCode::Char('c'), KeyModifiers::CONTROL);
        assert_eq!(InputHandler::parse_key(key), KeyCommand::CtrlC);
    }
}
