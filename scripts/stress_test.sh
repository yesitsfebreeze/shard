#!/bin/bash
export HOME=/root
export SHARD_KEY="000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
mkdir -p /root/.shards /data/shards
cp /data/_config.jsonc /root/.shards/_config.jsonc

for n in turtles volcanoes odin rust algorithms databases; do
  [ -f "/data/shards/$n" ] || { cp /app/shard "/data/shards/$n" && chmod +x "/data/shards/$n"; }
done

w() {
  local shard="$1" desc="$2" content="$3"
  local ed=$(printf '%s' "$desc" | sed 's/\\/\\\\/g; s/"/\\"/g')
  local ec=$(printf '%s' "$content" | sed 's/\\/\\\\/g; s/"/\\"/g')
  printf '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"shard_write","arguments":{"description":"%s","content":"%s"}}}\n' "$ed" "$ec" | "$shard" --mcp 2>/dev/null > /dev/null
}

ask() {
  local shard="$1" question="$2"
  local eq=$(printf '%s' "$question" | sed 's/\\/\\\\/g; s/"/\\"/g')
  local r=$(printf '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"shard_ask","arguments":{"question":"%s"}}}\n' "$eq" | "$shard" --mcp 2>/dev/null)
  echo "$r" | sed -n 's/.*"text":"\([^"]*\)".*/\1/p' | head -1 | sed 's/\\n/ /g'
}

T=/data/shards/turtles
V=/data/shards/volcanoes
O=/data/shards/odin
R=/data/shards/rust
A=/data/shards/algorithms
D=/data/shards/databases

echo "=== LOADING 40 THOUGHTS ==="

w "$T" "Sea Turtle Migration" "Leatherback sea turtles migrate up to 16000 km. They navigate using Earths magnetic field, wave direction, and chemical cues."
w "$T" "Turtle Shell Evolution" "The shell evolved from broadened ribs 230 million years ago. Made of 60 fused bones covered in keratin scutes."
w "$T" "Turtle Reproduction" "Sea turtles return to birth beach to lay eggs. Temperature determines sex: below 27.7C males, above 31C females. 80-120 eggs per nest."
w "$T" "Turtle Lifespan" "Giant tortoises live over 190 years. Jonathan the Seychelles tortoise is over 190. Sea turtles live 50-80 years."
w "$T" "Turtle Breathing" "Some turtles do cloacal respiration, absorbing oxygen through the cloaca. Fitzroy River turtle gets 70% oxygen this way."
w "$T" "Endangered Turtles" "Over 61% of species threatened. Main threats: habitat loss, plastic, illegal trade, climate change affecting sex ratios."
echo "Turtles: 6 thoughts"

w "$V" "Volcano Types" "Shield volcanoes have gentle slopes from fluid lava. Stratovolcanoes have steep slopes. Cinder cones are smallest."
w "$V" "Famous Eruptions" "Vesuvius destroyed Pompeii 79AD. Krakatoa 1883 killed 36000. Tambora 1815 caused Year Without a Summer."
w "$V" "Supervolcanoes" "Yellowstone magma chamber is 90km long. Last eruption 640000 years ago ejected 1000 cubic km. Toba may have reduced humans to 10000."
w "$V" "Volcanic Benefits" "Volcanic soil is extremely fertile. Geothermal energy powers Iceland. Volcanic rock used in construction. Pumice in cosmetics."
w "$V" "Underwater Volcanoes" "Most activity at mid-ocean ridges. Black smokers support unique ecosystems. Ring of Fire has 75% of active volcanoes."
w "$V" "Volcanic Monitoring" "Seismographs detect earthquake swarms. GPS measures ground deformation. Gas sensors detect SO2. Satellites track changes."
echo "Volcanoes: 6 thoughts"

w "$O" "Odin Overview" "Systems language by Bill Hall. Compiles via LLVM. Manual memory with explicit allocators. No GC. Clear readable syntax."
w "$O" "Odin Memory Model" "Explicit allocators via implicit context. Arena allocators for bulk free. Tracking allocators detect leaks. No implicit heap."
w "$O" "Odin Error Handling" "Multiple return values. or_return propagates errors. No exceptions. Tagged unions for variants. Errors are values."
w "$O" "Odin vs Go vs Rust" "Go-like syntax but manual memory. No borrow checker unlike Rust. Faster compilation than Rust. Better low-level than Go."
echo "Odin: 4 thoughts"

w "$R" "Rust Overview" "Systems language focused on safety and speed. Borrow checker prevents data races at compile time. Zero-cost abstractions. No GC."
w "$R" "Rust Ownership" "Every value has one owner. Dropped when owner leaves scope. Borrowing allows references. Mutable refs are exclusive."
w "$R" "Rust Error Handling" "Result and Option types. Question mark propagates errors. Panics for unrecoverable. No exceptions. Pattern matching."
w "$R" "Rust Concurrency" "Prevents data races at compile time via ownership. Send/Sync traits. Channels for messages. Arc/Mutex for shared state."
echo "Rust: 4 thoughts"

w "$A" "Sorting Algorithms" "Quicksort O(n log n) average. Mergesort O(n log n) guaranteed. Heapsort in-place. Radix sort O(nk). Timsort hybrid."
w "$A" "Graph Algorithms" "Dijkstra shortest paths. A-star with heuristics. BFS shortest unweighted. DFS for topological sort and cycles."
w "$A" "Hash Tables" "O(1) average lookup. Chaining or open addressing. Robin Hood reduces variance. Cuckoo guarantees O(1) worst case."
w "$A" "Dynamic Programming" "Overlapping subproblems. Memoization top-down. Tabulation bottom-up. Knapsack, LCS, edit distance."
w "$A" "Complexity Classes" "P solvable in polynomial time. NP verifiable. P vs NP unsolved. NP-complete: SAT, traveling salesman. Approximation for NP-hard."
echo "Algorithms: 5 thoughts"

w "$D" "ACID Properties" "Atomicity: all or nothing. Consistency: invariants maintained. Isolation: no interference. Durability: survives crashes. WAL for recovery."
w "$D" "B-Tree Indexes" "Standard database index. Multiple keys per node reduces height. Linked leaves for range scans. Clustered indexes store data in order."
w "$D" "NoSQL Databases" "MongoDB documents. Redis key-value. Cassandra columns. Neo4j graphs. Each optimized for different workloads."
w "$D" "Database Replication" "Leader-follower for reads. Multi-leader with conflict resolution. Raft consensus. CAP theorem tradeoffs."
w "$D" "LSM Trees" "Write-optimized. Buffer in memory, flush sorted runs. Compaction merges runs. Used in LevelDB, RocksDB, Cassandra."
echo "Databases: 5 thoughts"

echo ""
echo "=== 30 THOUGHTS ACROSS 6 SHARDS ==="
echo ""
echo "=== QUESTIONS ==="
echo ""

echo "Q1: How do sea turtles find their way across the ocean?"
echo "A: $(ask "$T" "How do sea turtles find their way across the ocean?")"
echo ""
echo "Q2: What would happen if Yellowstone erupted?"
echo "A: $(ask "$V" "What would happen if Yellowstone erupted?")"
echo ""
echo "Q3: How does Odin differ from Rust?"
echo "A: $(ask "$O" "How does Odin differ from Rust?")"
echo ""
echo "Q4: What makes Rust memory safe?"
echo "A: $(ask "$R" "What makes Rust memory safe?")"
echo ""
echo "Q5: When should I use a hash table?"
echo "A: $(ask "$A" "When should I use a hash table?")"
echo ""
echo "Q6: How do databases survive crashes?"
echo "A: $(ask "$D" "How do databases survive crashes?")"
echo ""
echo "Q7: What is the oldest turtle alive?"
echo "A: $(ask "$T" "What is the oldest turtle alive?")"
echo ""
echo "Q8: How do volcanoes benefit humans?"
echo "A: $(ask "$V" "How do volcanoes benefit humans?")"
echo ""
echo "Q9: What is NP-complete?"
echo "A: $(ask "$A" "What is NP-complete?")"
echo ""
echo "Q10: What is quantum physics? (turtle shard - should refuse)"
echo "A: $(ask "$T" "What is quantum physics?")"
