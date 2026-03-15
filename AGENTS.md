# Agent Instructions

This project uses a shared agent workflow for spec generation. Any AI coding agent can run it.

## Spec Generator (Wolf)

The full prompt lives at `.wolf/wolf.agent.md`. When asked to generate specs, process notes, or run wolf, follow that file.

### Quick summary

1. Read `notes.md` (freeform brain dump)
2. Extract features, assign categories and priorities
3. Confirm with the user before generating
4. Create `.wolf/<slug>/spec.md` for each feature
5. Create `.wolf/<slug>/todos/001.md`...`NNN.md` for implementation steps
6. Trigger roadmap creation when 6+ specs exist
7. Update `.wolf/index.md`
8. Recommend top 3 next actions

### Trigger phrases

- "generate specs"
- "run wolf"
- "process notes"
- "spec my notes"

### Key rules

- Never overwrite existing specs
- Never modify `notes.md`
- Always confirm with the user before generating
- `roadmap.md` lives in project root
