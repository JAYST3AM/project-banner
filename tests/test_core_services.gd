extends TestCase
## Core service checks: config, clock, RNG determinism and the save round-trip.


func run() -> void:
	await _tick()
	_test_config()
	_test_clock()
	_test_rng_determinism()
	await _test_save_round_trip()


func _test_config() -> void:
	section("config")
	var cfg := GameConfig.load_from(GameConfig.DEFAULT_CONFIG_PATH)
	check(cfg.is_valid(), "game_config.json loads without error")
	equal(cfg.get_int("config_version", -1), 1, "config declares version 1")
	equal(cfg.get_int("campaign.starting_gold", 0), 250, "starting gold comes from config")
	equal(cfg.get_int("xp.per_kill", 0), 20, "xp.per_kill comes from config")
	equal(cfg.get_value("travel.does_not_exist", "fallback"), "fallback",
		"missing config path returns the caller default")
	check(cfg.get_float("battle.field_width", 0.0) > 0.0, "battle field width is positive")

	# Every tunable the gameplay code reads must exist, or a typo silently
	# becomes a default. This is the guard for that.
	for path in [
		"campaign.starting_gold", "campaign.max_party_size",
		"time.seconds_per_game_hour", "time.hours_per_day",
		"time.starting_day", "time.starting_hour", "time.default_speed",
		"travel.world_units_per_game_hour", "travel.arrival_radius",
		"battle.tick_rate", "battle.max_duration_seconds",
		"battle.field_width", "battle.field_height",
		"xp.participation", "xp.per_kill", "xp.survived_battle", "xp.victory",
		"xp.level_curve_base", "xp.level_curve_growth",
		"rewards.gold_per_defeated_min", "rewards.gold_per_defeated_max",
		"encounters.trigger_radius",
	]:
		check(cfg.get_value(path, null) != null, "config defines '%s'" % path)


func _test_clock() -> void:
	section("campaign clock")
	var cfg := GameConfig.load_from(GameConfig.DEFAULT_CONFIG_PATH)
	var clock := CampaignClock.new(cfg)
	clock.day = 1
	clock.hour = 8.0
	clock.set_speed(CampaignClock.Speed.NORMAL)

	equal(clock.full_string(), "Day 1 - 08:00", "clock formats day and time")

	# 2 real seconds per game hour at normal speed => 2 real seconds = 1 hour.
	clock.advance_real_seconds(2.0)
	approx(clock.hour, 9.0, 0.001, "2 real seconds advances 1 game hour at normal speed")

	clock.set_speed(CampaignClock.Speed.FAST)
	clock.advance_real_seconds(2.0)
	approx(clock.hour, 12.0, 0.001, "fast speed advances 3x game time")

	clock.set_speed(CampaignClock.Speed.PAUSED)
	var advanced := clock.advance_real_seconds(10.0)
	approx(advanced, 0.0, 0.0001, "paused clock advances nothing")
	approx(clock.hour, 12.0, 0.001, "paused clock keeps the hour unchanged")

	# Day rollover
	clock.set_speed(CampaignClock.Speed.NORMAL)
	clock.hour = 23.0
	clock.advance_hours(3.0)
	equal(clock.day, 2, "passing midnight rolls the day over")
	approx(clock.hour, 2.0, 0.001, "rollover keeps the leftover hours")
	equal(clock.day_string(), "Day 2", "day string reflects rollover")

	# Save/load of clock state
	var restored := CampaignClock.new(cfg)
	restored.from_dict(clock.to_dict())
	equal(restored.day, clock.day, "clock day survives a round trip")
	approx(restored.hour, clock.hour, 0.001, "clock hour survives a round trip")
	equal(int(restored.speed), int(clock.speed), "clock speed survives a round trip")


func _test_rng_determinism() -> void:
	section("seeded rng")
	var a := RngService.new(12345)
	var b := RngService.new(12345)
	var c := RngService.new(54321)

	var seq_a: Array[int] = []
	var seq_b: Array[int] = []
	for i in 10:
		seq_a.append(a.stream("world").randi_range(0, 100000))
		seq_b.append(b.stream("world").randi_range(0, 100000))
	equal(seq_a, seq_b, "same campaign seed produces the same sequence")
	not_equal(seq_a, _first_n(RngService.new(54321), "world", 10), "different seed produces a different sequence")

	# Streams must be independent: consuming one must not shift another.
	var s1 := a.stream("bandits").randi_range(0, 100000)
	var _sink := a.stream("world").randi_range(0, 100000)
	var s2 := a.stream("bandits").randi_range(0, 100000)
	equal(s1, s2, "a named stream is stable regardless of other streams being read")
	equal(c.derive_seed("world"), c.derive_seed("world"), "derive_seed is stable")


func _first_n(rng: RngService, stream_name: String, count: int) -> Array[int]:
	var out: Array[int] = []
	for i in count:
		out.append(rng.stream(stream_name).randi_range(0, 100000))
	return out


func _test_save_round_trip() -> void:
	section("save / load")
	SaveManager.delete_all_saves()
	await _tick()

	var cfg := GameManager.config()
	check(cfg != null, "GameManager exposes a config")
	check(not SaveManager.has_save(), "no save exists after clearing")

	var state := CampaignState.create(cfg, "Round Trip Test", 4242)
	state.campaign_id = "camp_test_1"
	state.player_gold = 777
	state.world_position = Vector2(123.5, 456.25)
	state.destination_id = "greywatch"
	state.clock.day = 9
	state.clock.hour = 17.5
	state.flags["hello"] = "world"

	# A soldier with history, to prove the whole record survives.
	var s := Soldier.new()
	s.first_name = "Aldric"
	s.surname = "Harrow"
	s.unit_type_id = "peasant_recruit"
	s.age = 21
	s.level = 3
	s.xp = 42
	s.max_hp = 40
	s.hp = 27
	s.kills = 5
	s.battles_fought = 4
	s.battles_survived = 3
	s.add_trait("brave")
	s.add_trait("steady")
	s.record_history(4, "battle", "Survived the skirmish at the ford")
	state.register_soldier(s)
	state.player_party.add_member(s.id)

	var enemy_party := Party.new()
	enemy_party.id = "bandits_1"
	enemy_party.kind = Party.KIND_BANDIT
	enemy_party.display_name = "Road Bandits"
	state.enemy_parties["bandits_1"] = enemy_party

	var settlement := Settlement.new()
	settlement.id = "greywatch"
	settlement.name = "Greywatch"
	settlement.type = Settlement.TYPE_TOWN
	settlement.position = Vector2(300, 620)
	settlement.population = 1800
	settlement.recruit_pool = {"peasant_recruit": 6}
	state.settlements["greywatch"] = settlement

	check(SaveManager.save_campaign(state), "campaign saves without error")
	check(SaveManager.has_save(), "save file exists after saving")

	var meta := SaveManager.peek_metadata()
	equal(meta.get("campaign_name"), "Round Trip Test", "metadata exposes the campaign name")
	equal(meta.get("day"), 9, "metadata exposes the day")
	equal(meta.get("player_gold"), 777, "metadata exposes gold")
	equal(meta.get("party_size"), 1, "metadata exposes party size")

	var loaded := SaveManager.load_campaign(SaveManager.SLOT_DEFAULT, cfg)
	not_null(loaded, "campaign loads back")
	if loaded == null:
		return
	equal(loaded.campaign_id, "camp_test_1", "campaign id restored")
	equal(loaded.campaign_name, "Round Trip Test", "campaign name restored")
	equal(loaded.campaign_seed, 4242, "campaign seed restored")
	equal(loaded.player_gold, 777, "gold restored")
	approx(loaded.world_position.x, 123.5, 0.001, "world x restored")
	approx(loaded.world_position.y, 456.25, 0.001, "world y restored")
	equal(loaded.destination_id, "greywatch", "destination restored")
	equal(loaded.clock.day, 9, "campaign day restored")
	approx(loaded.clock.hour, 17.5, 0.001, "campaign hour restored")
	equal(loaded.flags.get("hello"), "world", "flags bag restored")
	equal(loaded.settlements.size(), 1, "settlements restored")
	equal(loaded.enemy_parties.size(), 1, "enemy parties restored")
	equal(loaded.player_party.member_ids.size(), 1, "party membership restored")

	var loaded_soldier := loaded.soldier(s.id)
	not_null(loaded_soldier, "the soldier is found by id after loading")
	if loaded_soldier != null:
		equal(loaded_soldier.full_name(), "Aldric Harrow", "soldier name restored")
		equal(loaded_soldier.unit_type_id, "peasant_recruit", "soldier unit type restored")
		equal(loaded_soldier.level, 3, "soldier level restored")
		equal(loaded_soldier.xp, 42, "soldier xp restored")
		equal(loaded_soldier.hp, 27, "soldier hp restored")
		equal(loaded_soldier.max_hp, 40, "soldier max hp restored")
		equal(loaded_soldier.kills, 5, "soldier kills restored")
		equal(loaded_soldier.battles_fought, 4, "battles fought restored")
		equal(loaded_soldier.battles_survived, 3, "battles survived restored")
		var expected_traits: Array[String] = ["brave", "steady"]
		equal(loaded_soldier.traits, expected_traits, "traits restored")
		equal(loaded_soldier.history.size(), 1, "personal history restored")
		equal(loaded_soldier.age, 21, "age restored")

	# Next generated id must not collide with a loaded one.
	not_equal(loaded.next_soldier_id(), s.id, "next soldier id does not reuse a loaded id")

	var loaded_settlement := loaded.settlement("greywatch")
	not_null(loaded_settlement, "settlement restored by id")
	if loaded_settlement != null:
		equal(loaded_settlement.name, "Greywatch", "settlement name restored")
		equal(loaded_settlement.population, 1800, "settlement population restored")
		equal(int(loaded_settlement.recruit_pool.get("peasant_recruit", 0)), 6,
			"settlement recruit pool restored")

	SaveManager.delete_all_saves()
	await _tick()
