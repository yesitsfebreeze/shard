//! Viewport - manages which lines are visible and cursor centering

/// Represents the visible portion of the file on screen
#[derive(Clone, Debug)]
pub struct Viewport {
    /// Screen height in lines
    pub height: usize,
    /// Index of first visible line in buffer
    pub top_line: usize,
}

impl Viewport {
    /// Create new viewport with given height
    pub fn new(height: usize) -> Self {
        Viewport {
            height,
            top_line: 0,
        }
    }

    /// Calculate scroll position to center cursor on screen
    ///
    /// Handles boundaries by adding virtual blank lines:
    /// - Near top: pad with virtual lines above
    /// - Near bottom: pad with virtual lines below
    /// - Prefer upper-middle position if screen height is even
    pub fn center_on_cursor(cursor_line: usize, buffer_len: usize, screen_height: usize) -> (usize, usize) {
        let center = screen_height / 2;

        let top_line = if cursor_line < center {
            // Near top: show from line 0
            0
        } else if cursor_line >= buffer_len.saturating_sub(1) {
            // Near bottom: show from end
            buffer_len.saturating_sub(screen_height).max(0)
        } else {
            // Middle: center the cursor
            cursor_line.saturating_sub(center)
        };

        let visual_cursor_row = if cursor_line < center {
            // Virtual lines above, cursor is lower on screen
            cursor_line
        } else if cursor_line >= buffer_len.saturating_sub(1) {
            // Virtual lines below, cursor is higher on screen
            screen_height.saturating_sub(buffer_len.saturating_sub(cursor_line))
        } else {
            // Cursor at center
            center
        };

        (top_line, visual_cursor_row)
    }

    /// Update viewport based on cursor position
    pub fn update(&mut self, cursor_line: usize, buffer_len: usize) {
        let (top_line, _) = Self::center_on_cursor(cursor_line, buffer_len, self.height);
        self.top_line = top_line;
    }

    /// Get range of visible lines
    pub fn visible_range(&self) -> std::ops::Range<usize> {
        self.top_line..self.top_line + self.height
    }

    /// Check if a line is currently visible
    pub fn is_visible(&self, line: usize) -> bool {
        line >= self.top_line && line < self.top_line + self.height
    }

    /// Update screen height (e.g., on terminal resize)
    pub fn set_height(&mut self, height: usize) {
        self.height = height;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_center_cursor_at_top() {
        let (top, visual) = Viewport::center_on_cursor(0, 100, 10);
        assert_eq!(top, 0);
        assert_eq!(visual, 0);
    }

    #[test]
    fn test_center_cursor_in_middle() {
        let (top, visual) = Viewport::center_on_cursor(50, 100, 10);
        assert_eq!(top, 45);
        assert_eq!(visual, 5);
    }

    #[test]
    fn test_center_cursor_at_bottom() {
        let (top, visual) = Viewport::center_on_cursor(99, 100, 10);
        assert_eq!(top, 90);
        assert_eq!(visual, 9);
    }

    #[test]
    fn test_small_buffer() {
        // Buffer smaller than screen
        let (top, visual) = Viewport::center_on_cursor(0, 3, 10);
        assert_eq!(top, 0); // Show from start
        assert_eq!(visual, 0);
    }

    #[test]
    fn test_visible_range() {
        let mut vp = Viewport::new(10);
        vp.top_line = 5;
        assert_eq!(vp.visible_range(), 5..15);
    }

    #[test]
    fn test_is_visible() {
        let mut vp = Viewport::new(10);
        vp.top_line = 5;
        assert!(!vp.is_visible(4));
        assert!(vp.is_visible(5));
        assert!(vp.is_visible(14));
        assert!(!vp.is_visible(15));
    }
}
