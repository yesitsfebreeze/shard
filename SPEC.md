# TUI Specification

## Core Features

### Rendering
- [x] Full-screen terminal UI with alternate screen buffer
- [x] No flickering or scrolling artifacts
- [x] Top status bar (fixed)
- [x] Bottom status bar (fixed)
- [x] Content area with file viewer

### Input
- [x] Raw input mode (no echo)
- [x] Arrow keys (up/down) for cursor movement
- [x] Mouse scroll wheel support
- [x] Quit on 'q' or Ctrl+C
- [ ] Page up/down navigation
- [ ] Home/End keys

### File Viewing
- [x] Load and display files line by line
- [x] Cursor position tracking
- [x] Viewport scrolling to follow cursor
- [x] Line count display

### Terminal Management
- [x] Initialize raw mode
- [x] Cleanup on exit
- [x] Mouse tracking enabled
- [x] Alternate screen buffer

### Logging
- [x] Write logs to exe directory
- [x] Timestamp each entry
- [x] Multiple log levels (info, error, debug)

## Nice to Have
- [ ] Syntax highlighting
- [ ] Search functionality
- [ ] Line number display
- [ ] Config file support
- [ ] Multiple file tabs
