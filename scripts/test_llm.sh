#!/bin/bash
set -e

SHARD=/app/shard
DATA=/tmp/shard-test
export HOME=/root

rm -rf "$DATA" /root/.shards
mkdir -p "$DATA/shards" /root/.shards

cp /data/_config.jsonc /root/.shards/_config.jsonc

SHELL_SHARD="$DATA/shards/turtle-shell"
cp "$SHARD" "$SHELL_SHARD"
chmod +x "$SHELL_SHARD"

echo "=== Config loaded ==="
"$SHELL_SHARD" --info 2>&1 | head -5

echo ""
echo "=== Writing thoughts about turtle shells ==="

write() {
    local desc="$1" content="$2"
    local escaped_desc=$(echo "$desc" | sed 's/\\/\\\\/g; s/"/\\"/g')
    local escaped_content=$(echo "$content" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n' ' ')
    echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"shard_write","arguments":{"description":"'"$escaped_desc"'","content":"'"$escaped_content"'"}}}' \
        | "$SHELL_SHARD" --mcp 2>/dev/null | grep -o '"text":"[^"]*"' | head -1
}

ask() {
    local question="$1"
    local escaped=$(echo "$question" | sed 's/\\/\\\\/g; s/"/\\"/g')
    echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"shard_ask","arguments":{"question":"'"$escaped"'"}}}' \
        | "$SHELL_SHARD" --mcp 2>/dev/null
}

write "Turtle Shell Structure" "The turtle shell is made up of about 60 bones that include portions of the backbone and ribs. The shell is covered by scutes, which are horny plates made of keratin. The top part is called the carapace and the bottom is the plastron. They are connected by a bridge on each side."

write "Shell Defense Mechanism" "When threatened, most turtles can retract their head and limbs inside the shell for protection. The shell provides excellent defense against predators. Box turtles can completely close their shell using a hinged plastron."

write "Shell Growth and Repair" "A turtle shell grows with the turtle throughout its life. New layers of keratin are added under the existing scutes. If damaged, turtle shells can heal and regenerate over time, though severe damage may be permanent. Growth rings on scutes can sometimes indicate age."

echo "Done writing."

echo ""
echo "=== Querying for 'keratin' ==="
echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"shard_query","arguments":{"keyword":"keratin"}}}' \
    | "$SHELL_SHARD" --mcp 2>/dev/null | grep -o '"text":"[^"]*"'

echo ""
echo "=== Asking: What is a turtle shell made of? ==="
ANSWER=$(ask "What is a turtle shell made of?")
echo "$ANSWER" | grep -o '"text":"[^"]*"' | sed 's/\\n/\n/g'

echo ""
echo "=== Asking: How do turtles defend themselves? ==="
ANSWER=$(ask "How do turtles defend themselves?")
echo "$ANSWER" | grep -o '"text":"[^"]*"' | sed 's/\\n/\n/g'

echo ""
echo "=== Asking: Can a turtle shell heal? ==="
ANSWER=$(ask "Can a turtle shell heal if it gets damaged?")
echo "$ANSWER" | grep -o '"text":"[^"]*"' | sed 's/\\n/\n/g'

echo ""
echo "=== Done ==="
