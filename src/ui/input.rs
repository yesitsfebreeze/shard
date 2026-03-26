//! Input handling - parses keyboard events

use crossterm::event::{self, Event, KeyCode, KeyEvent, KeyModifiers};

/// Represents a user input command
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KeyCommand {
    // Navigation
    Up,
    Down,
    Left,
    Right,

    // Text input
    Char(char),
    Backspace,
    Delete,
    Enter,
    Tab,
    Escape,

    // Control commands
    CtrlC,
    CtrlN, // Next steps
    CtrlF, // Search
    CtrlO, // Open file into lens

    // Lens stack navigation
    AltUp,   // Navigate up one lens level (close current lens)
    AltDown, // Navigate down (re-open lens)

    Unknown,
}

/// Input event with modifier state for seamless lens transitions
#[derive(Debug, Clone, Copy)]
pub struct InputEvent {
    pub command: KeyCommand,
    pub alt_held: bool,
}

/// Handles keyboard input events
pub struct InputHandler;

impl InputHandler {
    /// Poll for a keyboard event with timeout
    pub fn poll(timeout: std::time::Duration) -> Option<InputEvent> {
        if event::poll(timeout).ok()? {
            match event::read().ok()? {
                Event::Key(key) => Some(Self::parse_key(key)),
                Event::Resize(_, _) => Some(InputEvent {
                    command: KeyCommand::Unknown,
                    alt_held: false,
                }),
                _ => None,
            }
        } else {
            None
        }
    }

    /// Parse a single key event to InputEvent
    fn parse_key(key: KeyEvent) -> InputEvent {
        let has_ctrl = key.modifiers.contains(KeyModifiers::CONTROL);
        let has_alt = key.modifiers.contains(KeyModifiers::ALT);

        let command = match key.code {
            // Always emit Up/Down - handle Alt in main.rs
            KeyCode::Up => KeyCommand::Up,
            KeyCode::Down => KeyCommand::Down,
            KeyCode::Left => KeyCommand::Left,
            KeyCode::Right => KeyCommand::Right,
            KeyCode::Backspace => KeyCommand::Backspace,
            KeyCode::Delete => KeyCommand::Delete,
            KeyCode::Enter => KeyCommand::Enter,
            KeyCode::Tab => KeyCommand::Tab,
            KeyCode::Esc => KeyCommand::Escape,
            KeyCode::Char('c') if has_ctrl => KeyCommand::CtrlC,
            KeyCode::Char('n') if has_ctrl => KeyCommand::CtrlN,
            KeyCode::Char('f') if has_ctrl => KeyCommand::CtrlF,
            KeyCode::Char('o') if has_ctrl => KeyCommand::CtrlO,
            KeyCode::Char(c) => KeyCommand::Char(c),
            _ => KeyCommand::Unknown,
        };

        InputEvent {
            command,
            alt_held: has_alt,
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

    #[test]
    fn test_parse_alt_up() {
        let key = KeyEvent::new(KeyCode::Up, KeyModifiers::ALT);
        assert_eq!(InputHandler::parse_key(key), KeyCommand::AltUp);
    }

    #[test]
    fn test_parse_ctrl_o() {
        let key = KeyEvent::new(KeyCode::Char('o'), KeyModifiers::CONTROL);
        assert_eq!(InputHandler::parse_key(key), KeyCommand::CtrlO);
    }
}
