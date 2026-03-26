# Claude Code Instructions

## Project Structure

- `src/` - Source code (one file per responsibility)
- `tmp/` - Temporary testing/debugging files (gitignored) - put all tools and test utilities here

## Web Browsing

Use the `/browse` skill from gstack for all web browsing. Never use `mcp__claude-in-chrome__*` tools.

### Available gstack skills:
- `/office-hours` - Schedule office hours
- `/plan-ceo-review` - Plan CEO review
- `/plan-eng-review` - Plan engineering review
- `/plan-design-review` - Plan design review
- `/design-consultation` - Get design consultation
- `/review` - Code review
- `/ship` - Ship changes
- `/land-and-deploy` - Land and deploy
- `/canary` - Canary deployment
- `/benchmark` - Run benchmarks
- `/browse` - Web browsing (primary tool)
- `/qa` - QA testing
- `/qa-only` - QA testing only
- `/design-review` - Design review
- `/setup-browser-cookies` - Setup browser cookies
- `/setup-deploy` - Setup deployment
- `/retro` - Retrospective
- `/investigate` - Investigate issues
- `/document-release` - Document release
- `/codex` - Code assistance
- `/cso` - CSO tool
- `/autoplan` - Auto planning
- `/careful` - Careful mode
- `/freeze` - Freeze changes
- `/guard` - Guard mode
- `/unfreeze` - Unfreeze changes
- `/gstack-upgrade` - Upgrade gstack

## Active Technologies
- Rust 1.75+ (001-interactive-editing-mode)
- File I/O (plain text, UTF-8); auto-save to disk (001-interactive-editing-mode)

## Recent Changes
- 001-interactive-editing-mode: Added Rust 1.75+
