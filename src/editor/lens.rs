//! Code lens buffer - intelligent suggestion buffer at cursor line
//! Shows filtered suggestions, completions, search results, etc.
//! Appears as a real buffer in the editor, not an overlay

/// The code lens buffer type determines what kind of suggestions it shows
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum LensType {
    /// File finder: search files, AI todos, recent files
    FileFinder,
    /// Search results: ripgrep, fzf, grep results
    Search,
    /// Symbol completions: variable names, methods, etc.
    Completions,
    /// Git operations: branches, commits, hunks
    Git,
    /// Command help and history
    Command,
}

/// Prefix modes for the input to change behavior
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum InputPrefix {
    /// Default: filter from suggestions
    Filter,
    /// @ripgrep pattern - search with ripgrep
    Ripgrep,
    /// @fzf pattern - fuzzy search
    Fzf,
    /// @ai prompt - get AI suggestions
    AiPrompt,
    /// @git - git operations
    Git,
}

/// A code lens buffer that appears at cursor line
/// Shows suggestions above/below the input line
/// Real buffer - renders like any other buffer content
#[derive(Clone, Debug)]
pub struct LensBuffer {
    /// Is the codelens currently active/visible?
    pub visible: bool,
    /// What type of suggestions this buffer shows
    pub lens_type: LensType,
    /// The input line the user types in (the "filter" line)
    pub input: String,
    /// Cursor position within input
    pub input_cursor: usize,
    /// Suggestions above the input line
    pub suggestions_above: Vec<SuggestionItem>,
    /// Suggestions below the input line (matching results)
    pub suggestions_below: Vec<SuggestionItem>,
    /// Currently selected suggestion (index in suggestions_below)
    pub selected_index: usize,
    /// Input prefix (@ripgrep, @fzf, @ai, etc.)
    pub prefix: InputPrefix,
    /// History for cycling through inputs
    history: Vec<String>,
    history_index: Option<usize>,
}

/// A single suggestion item
#[derive(Clone, Debug)]
pub struct SuggestionItem {
    /// Display text
    pub text: String,
    /// Metadata (filepath, line number, match context, etc.)
    pub metadata: String,
    /// Icon/indicator (✓, →, ~, etc.)
    pub icon: char,
}

impl LensBuffer {
    /// Create new code lens buffer (initially hidden)
    pub fn new() -> Self {
        LensBuffer {
            visible: false,
            lens_type: LensType::FileFinder,
            input: String::new(),
            input_cursor: 0,
            suggestions_above: Vec::new(),
            suggestions_below: Vec::new(),
            selected_index: 0,
            prefix: InputPrefix::Filter,
            history: Vec::new(),
            history_index: None,
        }
    }

    /// Show file finder codelens
    /// Shows AI todos above, recent files below
    pub fn show_file_finder(&mut self) {
        self.visible = true;
        self.lens_type = LensType::FileFinder;
        self.input.clear();
        self.input_cursor = 0;
        self.prefix = InputPrefix::Filter;
        self.history_index = None;
    }

    /// Show search codelens
    pub fn show_search(&mut self) {
        self.visible = true;
        self.lens_type = LensType::Search;
        self.input.clear();
        self.input_cursor = 0;
        self.prefix = InputPrefix::Filter;
        self.history_index = None;
    }

    /// Show completions codelens
    pub fn show_completions(&mut self) {
        self.visible = true;
        self.lens_type = LensType::Completions;
        self.input.clear();
        self.input_cursor = 0;
        self.prefix = InputPrefix::Filter;
        self.history_index = None;
    }

    /// Show command codelens
    pub fn show_command(&mut self) {
        self.visible = true;
        self.lens_type = LensType::Command;
        self.input.clear();
        self.input_cursor = 0;
        self.prefix = InputPrefix::Filter;
        self.history_index = None;
    }

    /// Hide the codelens buffer
    pub fn hide(&mut self) {
        self.visible = false;
    }

    /// Check if visible
    pub fn is_visible(&self) -> bool {
        self.visible
    }

    /// Get the total height this buffer would need on screen
    /// Used by renderer to calculate layout
    pub fn height(&self) -> usize {
        if !self.visible {
            return 0;
        }
        // 1 for input line + suggestions above + suggestions below
        1 + self.suggestions_above.len() + self.suggestions_below.len()
    }

    /// Insert character in input
    pub fn insert_char(&mut self, ch: char) {
        if self.input_cursor <= self.input.len() {
            // Check for prefix mode changes
            if ch == '@' && self.input_cursor == 0 {
                // Starting a prefix
                self.input.insert(self.input_cursor, ch);
                self.input_cursor += 1;
            } else if self.input_cursor == 1 && self.input.starts_with('@') {
                // After @, determine which prefix
                match ch {
                    'r' => self.prefix = InputPrefix::Ripgrep,
                    'f' => self.prefix = InputPrefix::Fzf,
                    'a' => self.prefix = InputPrefix::AiPrompt,
                    'g' => self.prefix = InputPrefix::Git,
                    _ => {}
                }
                self.input.insert(self.input_cursor, ch);
                self.input_cursor += 1;
            } else {
                self.input.insert(self.input_cursor, ch);
                self.input_cursor += 1;
            }
        }
        self.selected_index = 0; // Reset selection on input change
    }

    /// Delete character (backspace)
    pub fn delete_char(&mut self) {
        if self.input_cursor > 0 {
            self.input_cursor -= 1;
            self.input.remove(self.input_cursor);
            // Reset prefix if we deleted the @
            if self.input.is_empty() {
                self.prefix = InputPrefix::Filter;
            }
        }
        self.selected_index = 0;
    }

    /// Delete forward (delete key)
    pub fn delete_forward(&mut self) {
        if self.input_cursor < self.input.len() {
            self.input.remove(self.input_cursor);
        }
        self.selected_index = 0;
    }

    /// Move cursor left in input
    pub fn cursor_left(&mut self) {
        if self.input_cursor > 0 {
            self.input_cursor -= 1;
        }
    }

    /// Move cursor right in input
    pub fn cursor_right(&mut self) {
        if self.input_cursor < self.input.len() {
            self.input_cursor += 1;
        }
    }

    /// Move cursor to start
    pub fn cursor_home(&mut self) {
        self.input_cursor = 0;
    }

    /// Move cursor to end
    pub fn cursor_end(&mut self) {
        self.input_cursor = self.input.len();
    }

    /// Select previous suggestion
    pub fn select_prev(&mut self) {
        if self.selected_index > 0 {
            self.selected_index -= 1;
        }
    }

    /// Select next suggestion
    pub fn select_next(&mut self) {
        if self.selected_index < self.suggestions_below.len().saturating_sub(1) {
            self.selected_index += 1;
        }
    }

    /// Get currently selected suggestion
    pub fn selected_item(&self) -> Option<&SuggestionItem> {
        self.suggestions_below.get(self.selected_index)
    }

    /// Set suggestions (replaces all)
    pub fn set_suggestions(&mut self, above: Vec<SuggestionItem>, below: Vec<SuggestionItem>) {
        self.suggestions_above = above;
        self.suggestions_below = below;
        self.selected_index = 0;
    }

    /// Add item to suggestions below
    pub fn add_suggestion(&mut self, item: SuggestionItem) {
        self.suggestions_below.push(item);
    }

    /// Get all lines for rendering (above + input + below)
    pub fn get_lines(&self) -> Vec<String> {
        let mut lines = Vec::new();

        // Add suggestions above
        for item in &self.suggestions_above {
            lines.push(format!("{} {}", item.icon, item.text));
        }

        // Add blank line before input
        if !self.suggestions_above.is_empty() {
            lines.push(String::new());
        }

        // Input line placeholder (will be rendered with actual input in renderer)
        let input_display = if self.input.is_empty() {
            match self.lens_type {
                LensType::FileFinder => "Type to find files".to_string(),
                LensType::Search => "Type to search".to_string(),
                LensType::Completions => "Type to complete".to_string(),
                LensType::Git => "Git command".to_string(),
                LensType::Command => "Command".to_string(),
            }
        } else {
            self.input.clone()
        };
        lines.push(input_display);

        // Add blank line after input
        if !self.suggestions_below.is_empty() {
            lines.push(String::new());
        }

        // Add suggestions below
        for (idx, item) in self.suggestions_below.iter().enumerate() {
            let prefix = if idx == self.selected_index { "▶" } else { " " };
            lines.push(format!("{} {} - {}", prefix, item.text, item.metadata));
        }

        lines
    }

    /// Add to history
    pub fn add_history(&mut self, text: String) {
        if !text.is_empty() {
            self.history.push(text);
            self.history_index = None;
        }
    }

    /// Navigate previous history
    pub fn history_prev(&mut self) {
        if self.history.is_empty() {
            return;
        }

        match self.history_index {
            None => {
                self.history_index = Some(self.history.len() - 1);
            }
            Some(idx) if idx > 0 => {
                self.history_index = Some(idx - 1);
            }
            Some(_) => return,
        }

        if let Some(idx) = self.history_index {
            self.input = self.history[idx].clone();
            self.input_cursor = self.input.len();
        }
    }

    /// Navigate next history
    pub fn history_next(&mut self) {
        if let Some(idx) = self.history_index {
            if idx < self.history.len() - 1 {
                self.history_index = Some(idx + 1);
                self.input = self.history[idx + 1].clone();
                self.input_cursor = self.input.len();
            } else {
                self.history_index = None;
                self.input.clear();
                self.input_cursor = 0;
            }
        }
    }

    /// Clear all state
    pub fn clear(&mut self) {
        self.input.clear();
        self.input_cursor = 0;
        self.suggestions_above.clear();
        self.suggestions_below.clear();
        self.selected_index = 0;
        self.prefix = InputPrefix::Filter;
        self.history_index = None;
    }
}

impl Default for LensBuffer {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_new_codelens_hidden() {
        let lens = LensBuffer::new();
        assert!(!lens.is_visible());
        assert!(lens.input.is_empty());
    }

    #[test]
    fn test_show_search() {
        let mut lens = LensBuffer::new();
        lens.show_search();
        assert!(lens.is_visible());
        assert_eq!(lens.lens_type, LensType::Search);
    }

    #[test]
    fn test_insert_char() {
        let mut lens = LensBuffer::new();
        lens.show_search();
        lens.insert_char('t');
        lens.insert_char('e');
        lens.insert_char('s');
        lens.insert_char('t');
        assert_eq!(lens.input, "test");
    }
}
