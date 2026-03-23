#!/bin/bash
cd "$(git rev-parse --show-toplevel)" || exit 0
CACHE_DIR=".temp/cache"
[ -d "$CACHE_DIR" ] || exit 0

LINES=""
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
for f in "$CACHE_DIR"/*; do
  [ -f "$f" ] || continue
  KEY=$(basename "$f")
  VALUE=$(sed -n '1p' "$f")
  AUTHOR=$(sed -n '2p' "$f")
  EXPIRES=$(sed -n '3p' "$f")
  [ -n "$EXPIRES" ] && [ "$EXPIRES" \< "$NOW" ] && continue
  LINE="$KEY: $VALUE"
  [ -n "$AUTHOR" ] && LINE="$LINE [$AUTHOR]"
  LINES="${LINES}${LINES:+\\n}$LINE"
done

[ -z "$LINES" ] && exit 0

printf '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"SHARED WORKING MEMORY (primary context):\\n%s"}}' "$LINES"
