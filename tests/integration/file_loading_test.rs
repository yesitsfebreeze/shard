use shards_tui::file::FileBuffer;
use std::fs;
use tempfile::TempDir;

#[test]
fn test_load_file() {
    let temp_dir = TempDir::new().unwrap();
    let file_path = temp_dir.path().join("test.txt");
    fs::write(&file_path, "Line 1\nLine 2\nLine 3").unwrap();

    let buf = FileBuffer::load(&file_path).unwrap();
    assert_eq!(buf.len(), 3);
    assert_eq!(buf.lines[0], "Line 1");
    assert_eq!(buf.lines[1], "Line 2");
    assert_eq!(buf.lines[2], "Line 3");
}

#[test]
fn test_save_file() {
    let temp_dir = TempDir::new().unwrap();
    let file_path = temp_dir.path().join("test.txt");

    let buf = FileBuffer::new(
        file_path.clone(),
        vec!["Hello".to_string(), "World".to_string()],
    );
    buf.save().unwrap();

    let content = fs::read_to_string(&file_path).unwrap();
    assert_eq!(content, "Hello\nWorld");
}

#[test]
fn test_round_trip() {
    let temp_dir = TempDir::new().unwrap();
    let file_path = temp_dir.path().join("roundtrip.txt");

    // Create and save
    let original = FileBuffer::new(
        file_path.clone(),
        vec!["First".to_string(), "Second".to_string(), "Third".to_string()],
    );
    original.save().unwrap();

    // Load and verify
    let loaded = FileBuffer::load(&file_path).unwrap();
    assert_eq!(loaded.lines.len(), original.lines.len());
    assert_eq!(loaded.lines, original.lines);
}
