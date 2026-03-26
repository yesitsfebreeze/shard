use shards_tui::ui::Viewport;
use shards_tui::editor::CursorPosition;

#[test]
fn test_center_at_start() {
    let cursor_line = 0;
    let buffer_len = 100;
    let screen_height = 10;

    let (top_line, visual_row) = Viewport::center_on_cursor(cursor_line, buffer_len, screen_height);
    assert_eq!(top_line, 0);
    assert_eq!(visual_row, 0);
}

#[test]
fn test_center_at_end() {
    let cursor_line = 99;
    let buffer_len = 100;
    let screen_height = 10;

    let (top_line, visual_row) = Viewport::center_on_cursor(cursor_line, buffer_len, screen_height);
    assert_eq!(top_line, 90);
    assert!(visual_row <= screen_height);
}

#[test]
fn test_center_in_middle() {
    let cursor_line = 50;
    let buffer_len = 100;
    let screen_height = 10;

    let (top_line, visual_row) = Viewport::center_on_cursor(cursor_line, buffer_len, screen_height);
    assert_eq!(top_line, 45);
    assert_eq!(visual_row, 5); // Should be at center (10 / 2 = 5)
}

#[test]
fn test_small_buffer() {
    let cursor_line = 0;
    let buffer_len = 3;
    let screen_height = 10;

    let (top_line, visual_row) = Viewport::center_on_cursor(cursor_line, buffer_len, screen_height);
    assert_eq!(top_line, 0);
    assert_eq!(visual_row, 0);
}

#[test]
fn test_viewport_update() {
    let mut viewport = Viewport::new(10);
    viewport.update(50, 100);
    assert_eq!(viewport.top_line, 45);
}

#[test]
fn test_visible_range() {
    let mut viewport = Viewport::new(10);
    viewport.top_line = 5;
    let range = viewport.visible_range();
    assert_eq!(range.start, 5);
    assert_eq!(range.end, 15);
}

#[test]
fn test_is_visible() {
    let mut viewport = Viewport::new(10);
    viewport.top_line = 5;

    assert!(!viewport.is_visible(4));
    assert!(viewport.is_visible(5));
    assert!(viewport.is_visible(10));
    assert!(viewport.is_visible(14));
    assert!(!viewport.is_visible(15));
}
