#!/bin/bash
set -e

PASS=0
FAIL=0
SHARD=/app/shard
DATA=/tmp/shard-test
export HOME=/root
export SHARD_KEY="000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"

run_test() {
    local name="$1"; shift
    echo ""
    echo "=== TEST: $name ==="
    if "$@" 2>&1; then
        echo "--- PASS: $name"
        PASS=$((PASS + 1))
    else
        echo "--- FAIL: $name (exit $?)"
        FAIL=$((FAIL + 1))
    fi
}

expect_contains() {
    local name="$1"; local expected="$2"; shift 2
    echo ""
    echo "=== TEST: $name ==="
    local output
    output=$("$@" 2>&1) || true
    if echo "$output" | grep -q "$expected"; then
        echo "$output" | head -20
        echo "--- PASS: $name (found '$expected')"
        PASS=$((PASS + 1))
    else
        echo "$output" | head -20
        echo "--- FAIL: $name (expected '$expected' not found)"
        FAIL=$((FAIL + 1))
    fi
}

rm -rf "$DATA"

echo "=============================="
echo "SHARD V3 INTEGRATION TEST"
echo "=============================="
echo "Data dir: $DATA"
echo "Key: $SHARD_KEY"

mkdir -p "$DATA/shards" "$VAULT"

SHELL_SHARD="$DATA/shards/turtle-shell"
BRAIN_SHARD="$DATA/shards/turtle-brain"
SKIN_SHARD="$DATA/shards/turtle-skin"

cp "$SHARD" "$SHELL_SHARD"
cp "$SHARD" "$BRAIN_SHARD"
cp "$SHARD" "$SKIN_SHARD"
chmod +x "$SHELL_SHARD" "$BRAIN_SHARD" "$SKIN_SHARD"

echo ""
echo "--- Fetching Wikipedia content ---"

SHELL_TEXT=$(curl -s "https://en.wikipedia.org/w/api.php?action=query&titles=Turtle_shell&prop=extracts&exintro=1&explaintext=1&format=json" \
    | sed 's/.*"extract":"//' | sed 's/".*//' | head -c 2000)

BRAIN_TEXT=$(curl -s "https://en.wikipedia.org/w/api.php?action=query&titles=Turtle&prop=extracts&exintro=1&explaintext=1&format=json" \
    | sed 's/.*"extract":"//' | sed 's/".*//' | head -c 2000)

SKIN_TEXT=$(curl -s "https://en.wikipedia.org/w/api.php?action=query&titles=Reptile_scale&prop=extracts&exintro=1&explaintext=1&format=json" \
    | sed 's/.*"extract":"//' | sed 's/".*//' | head -c 2000)

echo "Shell text: ${#SHELL_TEXT} chars"
echo "Brain text: ${#BRAIN_TEXT} chars"
echo "Skin text: ${#SKIN_TEXT} chars"

echo ""
echo "--- Phase 1: Verify clean binaries ---"

expect_contains "shell-clean" "has data:     false" "$SHELL_SHARD" --info
expect_contains "brain-clean" "has data:     false" "$BRAIN_SHARD" --info
expect_contains "skin-clean" "has data:     false" "$SKIN_SHARD" --info

echo ""
echo "--- Phase 2: Write thoughts via MCP ---"

write_thought() {
    local shard="$1" desc="$2" content="$3"
    local escaped_desc=$(echo "$desc" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\n/\\n/g')
    local escaped_content=$(echo "$content" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\n/\\n/g' | tr '\n' ' ')
    local request='{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"shard_write","arguments":{"description":"'"$escaped_desc"'","content":"'"$escaped_content"'"}}}'
    echo "$request" | "$shard" --mcp 2>/dev/null | grep -o '"text":"[^"]*"' | head -1
}

WRITE1=$(write_thought "$SHELL_SHARD" "Turtle Shell Structure" "The turtle shell is a highly complex shield. $SHELL_TEXT")
echo "Write 1: $WRITE1"

WRITE2=$(write_thought "$SHELL_SHARD" "Shell Composition" "Turtle shells are made of about 60 bones covered by plates called scutes.")
echo "Write 2: $WRITE2"

WRITE3=$(write_thought "$BRAIN_SHARD" "Turtle Brain Anatomy" "Turtles have relatively small brains compared to body size. $BRAIN_TEXT")
echo "Write 3: $WRITE3"

WRITE4=$(write_thought "$BRAIN_SHARD" "Turtle Nervous System" "The turtle nervous system includes a brain, spinal cord, and peripheral nerves.")
echo "Write 4: $WRITE4"

WRITE5=$(write_thought "$SKIN_SHARD" "Turtle Skin and Scales" "Turtle skin is covered in scales made of keratin. $SKIN_TEXT")
echo "Write 5: $WRITE5"

WRITE6=$(write_thought "$SKIN_SHARD" "Turtle Skin Shedding" "Unlike snakes, turtles shed their skin in small pieces rather than all at once.")
echo "Write 6: $WRITE6"

echo ""
echo "--- Phase 3: Verify data persisted ---"

expect_contains "shell-has-data" "has data:     true" "$SHELL_SHARD" --info
expect_contains "brain-has-data" "has data:     true" "$BRAIN_SHARD" --info
expect_contains "skin-has-data" "has data:     true" "$SKIN_SHARD" --info

expect_contains "shell-thoughts" "unprocessed=" "$SHELL_SHARD" --info
expect_contains "brain-thoughts" "unprocessed=" "$BRAIN_SHARD" --info
expect_contains "skin-thoughts" "unprocessed=" "$SKIN_SHARD" --info

echo ""
echo "--- Phase 4: Query via MCP ---"

query_shard() {
    local shard="$1" keyword="$2"
    local request='{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"shard_query","arguments":{"keyword":"'"$keyword"'"}}}'
    echo "$request" | "$shard" --mcp 2>/dev/null | grep -o '"text":"[^"]*"' | head -1
}

QUERY1=$(query_shard "$SHELL_SHARD" "shell")
echo "Query shell for 'shell': $QUERY1"
expect_contains "query-shell" "results" echo "$QUERY1"

QUERY2=$(query_shard "$BRAIN_SHARD" "brain")
echo "Query brain for 'brain': $QUERY2"
expect_contains "query-brain" "results" echo "$QUERY2"

QUERY3=$(query_shard "$SKIN_SHARD" "skin")
echo "Query skin for 'skin': $QUERY3"
expect_contains "query-skin" "results" echo "$QUERY3"

echo ""
echo "--- Phase 5: Compact ---"

run_test "compact-shell" "$SHELL_SHARD" --compact
run_test "compact-brain" "$BRAIN_SHARD" --compact
run_test "compact-skin" "$SKIN_SHARD" --compact

expect_contains "shell-compacted" "processed=" "$SHELL_SHARD" --info
expect_contains "brain-compacted" "processed=" "$BRAIN_SHARD" --info
expect_contains "skin-compacted" "processed=" "$SKIN_SHARD" --info


echo ""
echo "--- Phase 7: Read back after restart ---"

expect_contains "shell-restart" "has data:     true" "$SHELL_SHARD" --info
expect_contains "brain-restart" "has data:     true" "$BRAIN_SHARD" --info
expect_contains "skin-restart" "has data:     true" "$SKIN_SHARD" --info

echo ""
echo "=============================="
echo "RESULTS: $PASS passed, $FAIL failed"
echo "=============================="

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
