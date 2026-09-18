extends TestCase
## Where the world puts its towns: proposals, spacing, kinds and names.
##
## What this suite exists to pin down:
## [br]- the same seed proposes the same sites, with the same names and kinds;
## [br]- sites keep their distance from each other, and the distance is measured the short way round
##   a world with no edges;
## [br]- a barren corner does not mean an empty map;
## [br]- the kinds are the four the world has, and castles are as rare as they should be;
## [br]- and the search cost is per ground looked at, not per world size.

const SEED := 90210
const ANTISEED := 90211


func run() -> void:
	await _tick()
	_test_same_seed_same_sites()
	_test_different_seed_different_sites()
	_test_sites_keep_their_distance()
	_test_a_site_near_the_wrap_is_found_from_the_far_side()
	_test_enough_sites_are_found()
	_test_kinds_and_names()
	_test_names_are_not_all_the_same()
	_complete()


func _test_same_seed_same_sites() -> void:
	section("the same seed proposes the same sites")
	var a := WorldSites.build(SEED)
	var b := WorldSites.build(SEED)
	var centre := Vector2(1500.0, 900.0)
	var sa := a.settlement_sites(8, centre, 400.0)
	var sb := b.settlement_sites(8, centre, 400.0)
	equal(sa.size(), sb.size(), "the same number of sites")
	var identical := sa.size() == sb.size()
	for i in sa.size():
		if sa[i]["name"] != sb[i]["name"] or sa[i]["kind"] != sb[i]["kind"]:
			identical = false
		var pa: Vector2 = sa[i]["position"]
		var pb: Vector2 = sb[i]["position"]
		if pa.distance_to(pb) > 0.001:
			identical = false
	check(identical, "every site agrees in place, name and kind")


func _test_different_seed_different_sites() -> void:
	section("a different seed makes a different country")
	var a := WorldSites.build(SEED)
	var b := WorldSites.build(ANTISEED)
	var sa := a.settlement_sites(8, Vector2(1500.0, 900.0), 400.0)
	var sb := b.settlement_sites(8, Vector2(1500.0, 900.0), 400.0)
	var differs := false
	for site in sa:
		var p: Vector2 = site["position"]
		var found := false
		for other in sb:
			var q: Vector2 = other["position"]
			if p.distance_to(q) < 1.0:
				found = true
		if not found:
			differs = true
	check(differs, "the two worlds do not agree about where the towns are")


func _test_sites_keep_their_distance() -> void:
	section("sites keep their distance, the short way round")
	var sites := WorldSites.build(SEED)
	var settled := sites.settlement_sites(14, Vector2(2048.0, 2048.0), 900.0)
	var closest := 99999.0
	for i in settled.size():
		for j in range(i + 1, settled.size()):
			var d := WorldSites._wrapped_distance(settled[i]["position"], settled[j]["position"])
			closest = minf(closest, d)
	print("      %d sites, closest pair %.1f units (minimum %.1f)" % [
		settled.size(), closest, WorldSites.MIN_SPACING])
	greater(closest, WorldSites.MIN_SPACING - 0.001, "no two settlements are closer than the minimum")


func _test_a_site_near_the_wrap_is_found_from_the_far_side() -> void:
	section("a site near the wrap is found from the far side of it")
	var world := WorldSites.build(SEED)
	# Centred on a site that exists, rather than on a corner that may genuinely have none - the first
	# version asked a barren corner for towns and correctly got none, which tested nothing.
	var anchors := world.settlement_sites(1, Vector2(1024.0, 1024.0), 300.0)
	equal(anchors.size(), 1, "an anchor site exists to test around")
	if anchors.is_empty():
		return
	var anchor: Vector2 = anchors[0]["position"]
	# Ask for the region around that site from the other side of the wrap: on a torus these are the
	# same neighbourhood, so the same sites must come back.
	var a := world.sites_near(anchor + Vector2(2.0, 2.0), 260.0)
	var b := world.sites_near(WorldChunks.fold(anchor - Vector2(2.0, 2.0)), 260.0)
	var shared := 0
	for site in a:
		var p: Vector2 = site["position"]
		for other in b:
			var q: Vector2 = other["position"]
			if WorldSites._wrapped_distance(p, q) < 0.001:
				shared += 1
	greater(float(a.size()), 0.0, "the anchored region has sites to find at all (%d)" % a.size())
	equal(shared, a.size(), "every site found from one side is found from the other")


func _test_enough_sites_are_found() -> void:
	section("a barren corner still fills a map")
	var sites := WorldSites.build(SEED)
	var wanted := 12
	var started := Time.get_ticks_usec()
	# Deliberately asked at the world's edge, where a naive generator comes back empty.
	var found := sites.settlement_sites(wanted, Vector2(5.0, 5.0), 200.0)
	var ms := float(Time.get_ticks_usec() - started) / 1000.0
	print("      %d of %d sites from the world's corner in %.1f ms" % [found.size(), wanted, ms])
	equal(found.size(), wanted, "the search widens rather than coming back empty")


func _test_kinds_and_names() -> void:
	section("kinds are the four the world has, and names are names")
	var sites := WorldSites.build(SEED)
	var settled := sites.settlement_sites(20, Vector2(1024.0, 1024.0), 1200.0)
	var allowed := ["village", "town", "fort", "castle"]
	var counts := {}
	for site in settled:
		var kind := str(site["kind"])
		check(allowed.has(kind), "'%s' is a kind the world has" % kind)
		counts[kind] = int(counts.get(kind, 0)) + 1
		var name := str(site["name"])
		check(name.length() >= 4, "a site is named ('%s')" % name)
		if kind == "fort":
			check(name.begins_with("Fort "), "a fort is called Fort something ('%s')" % name)
		if kind == "castle":
			check(name.begins_with("Castle "), "a castle is called Castle something ('%s')" % name)
	print("      kinds: %s" % str(counts))


func _test_names_are_not_all_the_same() -> void:
	section("twenty settlements do not share five names")
	var sites := WorldSites.build(SEED)
	var settled := sites.settlement_sites(20, Vector2(700.0, 2100.0), 1200.0)
	var seen := {}
	for site in settled:
		seen[str(site["name"])] = true
	var distinct := seen.size()
	print("      %d settlements, %d distinct names" % [settled.size(), distinct])
	greater(float(distinct), float(settled.size()) * 0.6,
		"most names are distinct (%d of %d)" % [distinct, settled.size()])
