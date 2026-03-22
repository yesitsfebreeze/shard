#!/bin/bash
CACHE=".temp/cache.json"
if [ ! -f "$CACHE" ] || [ ! -s "$CACHE" ]; then
  exit 0
fi
echo "Shared context from shard cache:"
# Format JSON as readable key: value pairs
sed 's/[{}"]//g; s/,/\n/g' "$CACHE" | while IFS=: read -r key val; do
  [ -n "$key" ] && echo "  $key: $val"
done
