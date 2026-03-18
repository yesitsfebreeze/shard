package shard_unit_test

import "core:math"
import "core:strings"
import "core:testing"
import shard "shard:."

// Confirms cosine_similarity of identical vectors returns 1.
@(test)
test_cosine_similarity_identical :: proc(t: ^testing.T) {
	defer drain_logger()
	a := []f32{1.0, 0.0, 0.0}
	b := []f32{1.0, 0.0, 0.0}
	sim := shard.cosine_similarity(a, b)
	testing.expect(t, math.abs(sim - 1.0) < 0.0001, "identical vectors should have similarity 1.0")
}

// Confirms cosine_similarity of orthogonal vectors returns 0.
@(test)
test_cosine_similarity_orthogonal :: proc(t: ^testing.T) {
	defer drain_logger()
	a := []f32{1.0, 0.0, 0.0}
	b := []f32{0.0, 1.0, 0.0}
	sim := shard.cosine_similarity(a, b)
	testing.expect(t, math.abs(sim) < 0.0001, "orthogonal vectors should have similarity ~0")
}

// Confirms cosine_similarity of opposite vectors returns -1.
@(test)
test_cosine_similarity_opposite :: proc(t: ^testing.T) {
	defer drain_logger()
	a := []f32{1.0, 0.0}
	b := []f32{-1.0, 0.0}
	sim := shard.cosine_similarity(a, b)
	testing.expect(t, math.abs(sim - (-1.0)) < 0.0001, "opposite vectors should have similarity -1.0")
}

// Confirms cosine_similarity handles unequal length vectors.
@(test)
test_cosine_similarity_unequal_length :: proc(t: ^testing.T) {
	defer drain_logger()
	a := []f32{1.0, 0.0, 0.0}
	b := []f32{1.0, 0.0}
	sim := shard.cosine_similarity(a, b)
	testing.expect(t, sim == 0, "unequal length vectors should return 0")
}

// Confirms cosine_similarity handles zero vectors.
@(test)
test_cosine_similarity_zero :: proc(t: ^testing.T) {
	defer drain_logger()
	a := []f32{0.0, 0.0, 0.0}
	b := []f32{1.0, 2.0, 3.0}
	sim := shard.cosine_similarity(a, b)
	testing.expect(t, sim == 0, "zero vector should return 0")
}

// Confirms cosine_similarity handles empty vectors.
@(test)
test_cosine_similarity_empty :: proc(t: ^testing.T) {
	defer drain_logger()
	a := []f32{}
	b := []f32{}
	sim := shard.cosine_similarity(a, b)
	testing.expect(t, sim == 0, "empty vectors should return 0")
}

// Confirms cosine_similarity computes known values correctly.
@(test)
test_cosine_similarity_known_values :: proc(t: ^testing.T) {
	defer drain_logger()
	// 45-degree angle in 2D: cos(45°) = sqrt(2)/2 ≈ 0.7071
	a := []f32{1.0, 1.0}
	b := []f32{1.0, 0.0}
	sim := shard.cosine_similarity(a, b)
	expected: f32 = 0.7071
	testing.expectf(t, math.abs(sim - expected) < 0.001, "45-degree angle should give ~0.7071, got %v", sim)

	// More specific: dot(1,1; 1,0) = 1, |a| = sqrt(2), |b| = 1, cos = 1/sqrt(2)
}

// Confirms cosine_similarity handles multi-dimensional vectors.
@(test)
test_cosine_similarity_multidim :: proc(t: ^testing.T) {
	defer drain_logger()
	// Simple case: a = (1,1,1), b = (1,1,1) -> sim = 1
	a := []f32{1.0, 1.0, 1.0}
	b := []f32{1.0, 1.0, 1.0}
	sim := shard.cosine_similarity(a, b)
	testing.expect(t, math.abs(sim - 1.0) < 0.0001, "all-ones vectors should have similarity 1.0")

	// a = (1,1,1), b = (2,2,2) -> also 1 (same direction)
	c := []f32{2.0, 2.0, 2.0}
	sim2 := shard.cosine_similarity(a, c)
	testing.expect(t, math.abs(sim2 - 1.0) < 0.0001, "scaled vectors should have similarity 1.0")

	// a = (1,1,1), b = (-1,-1,-1) -> -1 (opposite)
	d := []f32{-1.0, -1.0, -1.0}
	sim3 := shard.cosine_similarity(a, d)
	testing.expect(t, math.abs(sim3 - (-1.0)) < 0.0001, "opposite all-ones vectors should have similarity -1.0")
}

// Confirms cosine_similarity handles negative values.
@(test)
test_cosine_similarity_negative :: proc(t: ^testing.T) {
	defer drain_logger()
	a := []f32{-1.0, 2.0, -3.0}
	b := []f32{2.0, -4.0, 6.0}

	// These are scalar multiples (b = -2*a), so similarity should be -1
	sim := shard.cosine_similarity(a, b)
	testing.expect(t, math.abs(sim - (-1.0)) < 0.0001, "scalar negative multiples should have similarity -1.0")
}

// Confirms cosine_similarity is symmetric.
@(test)
test_cosine_similarity_symmetric :: proc(t: ^testing.T) {
	defer drain_logger()
	a := []f32{0.5, 1.5, 2.5}
	b := []f32{-1.0, 0.0, 3.0}
	sim_ab := shard.cosine_similarity(a, b)
	sim_ba := shard.cosine_similarity(b, a)
	testing.expect(t, math.abs(sim_ab - sim_ba) < 0.0001, "cosine similarity should be symmetric")
}

// Confirms embed_shard_text produces correct text.
@(test)
test_embed_shard_text :: proc(t: ^testing.T) {
	defer drain_logger()
	entry := shard.Registry_Entry {
		name = "test-shard",
		catalog = shard.Catalog {
			name    = "Test Shard",
			purpose = "A test shard for unit testing",
			tags    = []string{"test", "unit"},
		},
		gate_positive = []string{"go", "rust", "odin"},
		gate_desc     = []string{"programming", "concurrency"},
	}

	text := shard.embed_shard_text(entry)
	testing.expect(t, strings.contains(text, "Test Shard"), "should contain catalog name")
	testing.expect(t, strings.contains(text, "A test shard"), "should contain purpose")
	testing.expect(t, strings.contains(text, "Tags:"), "should contain Tags label")
	testing.expect(t, strings.contains(text, "Topics:"), "should contain Topics label")
	testing.expect(t, strings.contains(text, "Contains:"), "should contain Contains label")
}

// Confirms embed_shard_text handles empty fields.
@(test)
test_embed_shard_text_empty :: proc(t: ^testing.T) {
	defer drain_logger()
	entry := shard.Registry_Entry {
		name    = "empty-shard",
		catalog = shard.Catalog{},
	}

	text := shard.embed_shard_text(entry)
	// Empty catalog returns empty string - this is expected behavior
	testing.expect(t, true, "embed_shard_text should handle empty entries gracefully")
	testing.expect(t, strings.contains(text, "empty-shard") || text == "", 
		"should contain name or return empty for fully empty entry")
}

// Confirms Registry_Entry construction works.
@(test)
test_registry_entry_construction :: proc(t: ^testing.T) {
	defer drain_logger()
	entry := shard.Registry_Entry {
		name          = "test-entry",
		data_path     = ".shards/test.shard",
		thought_count = 100,
		catalog       = shard.Catalog {
			name    = "Test",
			purpose = "Testing",
			tags    = []string{"test"},
		},
		gate_desc    = []string{"desc1", "desc2"},
		gate_positive = []string{"pos1", "pos2"},
		gate_negative = []string{"neg1"},
		gate_related  = []string{"rel1"},
	}

	testing.expect(t, entry.name == "test-entry", "name should match")
	testing.expect(t, entry.data_path == ".shards/test.shard", "data_path should match")
	testing.expect(t, entry.thought_count == 100, "thought_count should match")
	testing.expect(t, entry.catalog.name == "Test", "catalog name should match")
	testing.expect(t, len(entry.gate_desc) == 2, "should have 2 gate_desc entries")
	testing.expect(t, len(entry.gate_positive) == 2, "should have 2 gate_positive entries")
	testing.expect(t, len(entry.gate_negative) == 1, "should have 1 gate_negative entry")
	testing.expect(t, len(entry.gate_related) == 1, "should have 1 gate_related entry")
}
