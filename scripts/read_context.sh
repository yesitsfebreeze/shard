#!/bin/bash
CACHE=".temp/cache.json"
if [ ! -f "$CACHE" ] || [ ! -s "$CACHE" ]; then
  exit 0
fi

node -e '
  try {
    const c = JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
    const now = new Date().toISOString();
    const lines = [];
    for (const [k,v] of Object.entries(c)) {
      if (v.expires && v.expires < now) continue;
      let line = k + ": " + v.value;
      if (v.author) line += " [" + v.author + "]";
      lines.push(line);
    }
    if (lines.length === 0) process.exit(0);
    const ctx = "SHARED WORKING MEMORY (primary context):\\n" + lines.join("\\n");
    console.log(JSON.stringify({
      hookSpecificOutput: {
        hookEventName: "UserPromptSubmit",
        additionalContext: ctx
      }
    }));
  } catch(e) {}
' "$CACHE" 2>/dev/null
