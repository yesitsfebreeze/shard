//! Shards TUI - Interactive collaborative editor with AI integration
//!
//! A terminal user interface for editing files with inline AI assistance.
//! Supports centered cursor navigation, real-time AI question/response,
//! and stacked file context navigation.

pub mod ai;
pub mod editor;
pub mod file;
pub mod ui;

// Public re-exports for main API
pub use ai::AiClient;
pub use editor::Editor;
pub use file::FileBuffer;
pub use ui::Terminal;

/// Application version
pub const VERSION: &str = env!("CARGO_PKG_VERSION");
