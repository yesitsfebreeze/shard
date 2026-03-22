#!/bin/bash

PASS=0
FAIL=0

run_test() {
    local name="$1"
    shift
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

expect_fail() {
    local name="$1"
    shift
    echo ""
    echo "=== TEST: $name (expect failure) ==="
    if "$@" 2>&1; then
        echo "--- FAIL: $name (expected failure but got success)"
        FAIL=$((FAIL + 1))
    else
        echo "--- PASS: $name (failed as expected)"
        PASS=$((PASS + 1))
    fi
}

expect_contains() {
    local name="$1"
    local expected="$2"
    shift 2
    echo ""
    echo "=== TEST: $name ==="
    local output
    output=$("$@" 2>&1) || true
    if echo "$output" | grep -q "$expected"; then
        echo "$output"
        echo "--- PASS: $name (found '$expected')"
        PASS=$((PASS + 1))
    else
        echo "$output"
        echo "--- FAIL: $name (expected '$expected' not found)"
        FAIL=$((FAIL + 1))
    fi
}

export HOME=/root

# Basic flags
run_test "version" /app/shard --version
run_test "help" /app/shard --help

# AI mode
expect_contains "help-ai" "AI AGENT INTERFACE" /app/shard --help --ai
expect_contains "version-ai" "shard 0.1.0" /app/shard --version --ai

# Info on clean binary (no data block)
expect_contains "info-clean" "has data:     false" /app/shard --info

# Append data with bad hash — should be rejected by hash verification
echo ""
echo "=== TEST: blob-hash-reject ==="
cp /app/shard /app/shard.bak
printf '\x00\x00\x00\x00' >> /app/shard   # processed count=0
printf '\x00\x00\x00\x00' >> /app/shard   # unprocessed count=0
printf '\x02\x00\x00\x00{}' >> /app/shard  # catalog len=2, data="{}"
printf '\x00\x00\x00\x00' >> /app/shard   # manifest len=0
printf '\x00\x00\x00\x00' >> /app/shard   # gates len=0
printf '\x16\x00\x00\x00' >> /app/shard   # data_size=22
dd if=/dev/zero bs=1 count=32 >> /app/shard 2>/dev/null  # bad hash (zeros)
printf '\x36\x30\x30\x30\x44\x52\x48\x53' >> /app/shard # magic
expect_contains "hash-rejects-bad-data" "has data:     false" /app/shard --info
cp /app/shard.bak /app/shard

# Daemon creates index entry and working copy
run_test "daemon-registers" /app/shard --daemon
expect_contains "index-has-entry" "/app/shard" cat /root/.shards/index/*

# Working copy created in run dir
echo ""
echo "=== TEST: working-copy-exists ==="
if ls /root/.shards/run/* >/dev/null 2>&1; then
    echo "--- PASS: working-copy-exists"
    PASS=$((PASS + 1))
else
    echo "--- FAIL: working-copy-exists (no files in run dir)"
    FAIL=$((FAIL + 1))
fi

# Info shows shard id and known shards
expect_contains "info-shows-shard-id" "shard id:" /app/shard --info
expect_contains "info-shows-index" "known shards:" /app/shard --info

expect_fail "unknown-flag" /app/shard --bogus

# Summary
echo ""
echo "=============================="
echo "RESULTS: $PASS passed, $FAIL failed"
echo "=============================="

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
