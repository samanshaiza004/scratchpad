package main

// Region revisions for the issue #231 adoption (tab strip and workspace tree).
//
// Alicorn's region cache is keyed on an application-owned, monotonic revision.
// Several natural inputs in Scratchpad are hashes, ids, counts, or scroll
// offsets: equal values mean "same output" but the values themselves do not
// increase. This helper turns such a signature into a monotonic generation:
// when the signature changes the generation advances by one, otherwise the
// generation is returned unchanged so the region stays cached.
//
// Region_Generation is app-owned state. It must live for the lifetime of the
// region and must not be reset while the region node is retained: a lower
// revision is rejected by both region_begin and invalidate_region.
Region_Generation :: struct {
	signature:  u64,
	generation: u64,
	seeded:     bool,
}

region_generation_next :: proc(state: ^Region_Generation, signature: u64) -> u64 {
	if state == nil { return 1 }
	value := signature
	if value == 0 { value = 1 }
	if !state.seeded || state.signature != value {
		state.signature = value
		state.generation += 1
		if state.generation == 0 { state.generation = 1 }
		state.seeded = true
	}
	return state.generation
}

// region_generation_peek returns the current revision without advancing it.
// Use it only when the caller knows the signature is unchanged (for example,
// invalidating a region for a state change that the next description will
// observe). A never-seeded generation returns 1 so the first invalidation is
// still monotonic relative to an unretained region.
region_generation_peek :: proc(state: ^Region_Generation) -> u64 {
	if state == nil || !state.seeded { return 1 }
	return state.generation
}

REGION_HASH_OFFSET :: u64(14_695_981_039_346_656_037)
REGION_HASH_PRIME :: u64(1_099_511_628_211)

region_hash_mix :: proc(hash: u64, value: u64) -> u64 {
	return (hash ~ value) * REGION_HASH_PRIME
}

region_hash_string :: proc(hash: u64, value: string) -> u64 {
	result := hash
	for index in 0..<len(value) { result = (result ~ u64(value[index])) * REGION_HASH_PRIME }
	result = (result ~ u64(len(value))) * REGION_HASH_PRIME
	return result
}

region_hash_bool :: proc(hash: u64, value: bool) -> u64 {
	return region_hash_mix(hash, 1 if value else 0)
}

region_hash_f32 :: proc(hash: u64, value: f32) -> u64 {
	// Layout/scroll values are compared as exact bits. Fractional offsets are
	// inputs to the described output (virtual list realization), so a changed
	// bit pattern must change the signature even if it rounds to the same pixel.
	return region_hash_mix(hash, u64(transmute(u32)value))
}
