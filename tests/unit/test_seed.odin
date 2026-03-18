package shard_unit_test

import "core:testing"
import shard "shard:."

// Smoke test — confirms the collection import resolves and the package compiles.
@(test)
test_package_compiles :: proc(t: ^testing.T) {
	// Verify a core public type is accessible from the collection.
	_ :: shard.Request
	testing.expect(t, true, "shard_unit_test package compiles")
}
