#!/bin/bash
cd "$(git rev-parse --show-toplevel)" || exit 0
CACHE=".temp/cache.json"
[ -f "$CACHE" ] || exit 0

node -e '
  const fs = require("fs");
  const f = process.argv[1];
  try {
    const c = JSON.parse(fs.readFileSync(f, "utf8"));
    c.last_active = {
      value: new Date().toISOString(),
      author: "system",
      expires: ""
    };
    fs.writeFileSync(f, JSON.stringify(c));
  } catch(e) {}
' "$CACHE" 2>/dev/null
