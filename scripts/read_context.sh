#!/bin/bash
CACHE=".temp/cache.json"
if [ ! -f "$CACHE" ] || [ ! -s "$CACHE" ]; then
  exit 0
fi
echo "Shared working memory:"
# Parse structured JSON cache entries
node -e '
  try {
    const c = JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
    const now = new Date().toISOString();
    for (const [k,v] of Object.entries(c)) {
      if (v.expires && v.expires < now) continue;
      let line = "  " + k + ": " + v.value;
      if (v.author) line += " [" + v.author + "]";
      console.log(line);
    }
  } catch(e) {}
' "$CACHE" 2>/dev/null || sed 's/[{}"]//g; s/,/\n/g' "$CACHE"
