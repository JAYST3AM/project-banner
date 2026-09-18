extends TestCase
## The campaign world as data: chunks, and a noise field that wraps.
##
## What this suite exists to pin down:
## [br]- the same seed always grows the same country, sample for sample;
## [br]- [b]the world wraps exactly[/b] - a sample at the far edge is the sample at the near edge,
##   not a value near it. A seam here would be visible forever, so this is the strongest test;
## [br]- chunk arithmetic and positions round-trip;
## [br]- generating a chunk costs what the streaming budget assumes it costs;
## [br]- and the cache is bounded, because a world nobody can walk off the end of must not grow in
##   memory as it is explored.

const SEED := 4242
const OTHER_SEED := 4243


func run() -> void:
	await _tick()
	_test_same_seed_same_country()
	_test_different_seed_different_country()
	_test_the_world_wraps_in_samples()
	_test_the_world_wraps_in_geometry()
	_test_chunk_round_trip()
	_test_chunk_cost()
	_test_cache_is_bounded()
	_test_cache_does_not_change_answers()
	# Declared, as every suite must: a suite that stops without saying so comes back looking like a
	# suite that never ran.
	_complete()


func _world(p_seed: int) -> WorldChunks:
	return WorldChunks.build(p_seed)


func _test_same_seed_same_country() -> void:
	section("the same seed grows the same country")
	var a := _world(SEED)
	var b := _world(SEED)
	var same := true
	var points := [Vector2(0, 0), Vector2(37.5, 812.25), Vector2(2048, 2048), Vector2(4095.5, 3.25)]
	for p in points:
		var sa := a.sample(p)
		var sb := b.sample(p)
		for key in sa.keys():
			if absf(float(sa[key]) - float(sb[key])) > 0.000001:
				same = false
	check(same, "two worlds from one seed agree at every sampled point")


func _test_different_seed_different_country() -> void:
	section("a different seed grows a different country")
	var a := _world(SEED)
	var b := _world(OTHER_SEED)
	var differs := false
	for i in 40:
		var p := Vector2(float(i) * 97.0, float(i) * 53.0)
		if absf(a.height_at(p) - b.height_at(p)) > 0.0001:
			differs = true
	check(differs, "the height field differs somewhere between two seeds")


func _test_the_world_wraps_in_samples() -> void:
	section("the world wraps: a sample at the edge is the sample at the far edge")
	var world := _world(SEED)
	# Across the wrap in x, in y, and over both. Exact equality, not nearness: the lattice period is
	# the world's size at every octave, so this is not an approximation that happens to look right.
	var pairs := [
		[Vector2(0.0, 512.0), Vector2(WorldChunks.WORLD_SIZE, 512.0)],
		[Vector2(512.0, 0.0), Vector2(512.0, WorldChunks.WORLD_SIZE)],
		[Vector2(3.5, 7.25), Vector2(WorldChunks.WORLD_SIZE + 3.5, WorldChunks.WORLD_SIZE + 7.25)],
		[Vector2(-1.0, -1.0), Vector2(WorldChunks.WORLD_SIZE - 1.0, WorldChunks.WORLD_SIZE - 1.0)],
	]
	var worst := 0.0
	for pair in pairs:
		var a: Dictionary = world.sample(pair[0])
		var b: Dictionary = world.sample(pair[1])
		for key in a.keys():
			worst = maxf(worst, absf(float(a[key]) - float(b[key])))
	approx(worst, 0.0, 0.000001, "samples either side of the wrap are identical (worst gap %.8f)" % worst)


func _test_the_world_wraps_in_geometry() -> void:
	section("positions fold into the world")
	approx(WorldChunks.fold(Vector2(WorldChunks.WORLD_SIZE + 10.0, -5.0)).x, 10.0, 0.0001, "x folds")
	approx(WorldChunks.fold(Vector2(WorldChunks.WORLD_SIZE + 10.0, -5.0)).y,
		WorldChunks.WORLD_SIZE - 5.0, 0.0001, "y folds the other way")


func _test_chunk_round_trip() -> void:
	section("chunk arithmetic round-trips")
	var cases := [Vector2(0.0, 0.0), Vector2(63.9, 63.9), Vector2(64.0, 0.0), Vector2(4095.0, 4095.0)]
	var good := true
	for p in cases:
		var chunk := WorldChunks.chunk_of(p)
		var origin := WorldChunks.chunk_origin(chunk)
		var back := WorldChunks.chunk_of(origin + Vector2(1.0, 1.0))
		if back != chunk:
			good = false
	check(good, "every chunk's origin is inside that chunk")
	# The far edge belongs to the first chunk, because the world wraps rather than ends.
	equal(WorldChunks.chunk_of(Vector2(WorldChunks.WORLD_SIZE, 0.0)), Vector2i(0, 0),
		"the far edge is the near edge")


func _test_chunk_cost() -> void:
	section("a chunk costs what the budget assumes")
	var world := _world(SEED)
	var started := Time.get_ticks_usec()
	var made := 0
	for cy in 8:
		for cx in 8:
			world.ensure_chunk(Vector2i(cx, cy))
			made += 1
	var elapsed_ms := float(Time.get_ticks_usec() - started) / 1000.0
	var per := elapsed_ms / float(made)
	var stats := world.stats()
	equal(int(stats["generated"]), made, "every requested chunk was generated once")
	print("      %d chunks in %.1f ms = %.3f ms a chunk | cached %d" % [
		made, elapsed_ms, per, int(stats["cached"])])
	less(per, 4.0, "a chunk is cheap enough for a streaming budget (%.3f ms)" % per)


func _test_cache_is_bounded() -> void:
	section("the cache is bounded, because the world is not")
	var world := _world(SEED)
	# A small limit, proved with a small number of chunks: the point is the eviction, not the size.
	world.cache_limit = 24
	for cy in 10:
		for cx in 10:
			world.ensure_chunk(Vector2i(cx, cy))
	check(world.cached_chunks() <= 24,
		"cached chunks stay at or under the limit (%d)" % world.cached_chunks())


func _test_cache_does_not_change_answers() -> void:
	section("evicting a chunk does not change what was in it")
	var world := _world(SEED)
	var first := world.sample(Vector2(600.0, 600.0))
	# Force the chunk holding that sample out by walking past a deliberately small limit.
	world.cache_limit = 24
	for cy in 10:
		for cx in 10:
			world.ensure_chunk(Vector2i(cx, cy))
	var again := world.sample(Vector2(600.0, 600.0))
	var same := true
	for key in first.keys():
		if absf(float(first[key]) - float(again[key])) > 0.000001:
			same = false
	check(same, "a sample is the same after its chunk has been evicted and rebuilt")
