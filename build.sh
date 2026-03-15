#!/bin/sh
# build.sh — bake SHARD_VERSION_HASH into shard.odin then compile.
#
# Steps:
#   1. Zero SHARD_VERSION_HASH in shard.odin
#   2. SHA256(shard.odin with hash zeroed)
#   3. Write hash bytes back into SHARD_VERSION_HASH
#   4. odin build .
#
# On startup the binary verifies footer build_hash == SHARD_VERSION_HASH.
# Zero SHARD_VERSION_HASH = dev/test mode (no verification).

set -e

cd "$(dirname "$0")"

# Step 1: zero SHARD_VERSION_HASH
sed -i.bak 's/SHARD_VERSION_HASH :: \[32\]u8{[^}]*}/SHARD_VERSION_HASH :: [32]u8{}/' shard.odin
rm -f shard.odin.bak

# Step 2: hash the zeroed source
if command -v sha256sum >/dev/null 2>&1; then
    HASH=$(sha256sum shard.odin | awk '{print $1}')
else
    HASH=$(shasum -a 256 shard.odin | awk '{print $1}')
fi

# Step 3: convert hex digest to Odin byte array literal and bake it in
BYTES=$(python3 -c "
h = '${HASH}'
print(', '.join(hex(int(h[i:i+2], 16)) for i in range(0, 64, 2)))
")
sed -i.bak "s/SHARD_VERSION_HASH :: \[32\]u8{}/SHARD_VERSION_HASH :: [32]u8{${BYTES}}/" shard.odin
rm -f shard.odin.bak

echo "baked SHARD_VERSION_HASH = ${HASH}"

# Step 4: compile
odin build . -out:shard "$@"
echo "built: shard"
