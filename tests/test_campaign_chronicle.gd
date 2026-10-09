extends TestCase
## Campaign history is a read-only presentation of persistent, factual events.
## The event store lives in flags for old-save compatibility. Battle history
## already belongs to BattleResolver and is adapted without a second write.

func run() -> void:
	await _tick()
	_test_empty_and_invalid_events()
	_test_recorded_order_filters_and_snapshot_safety()
	_test_battle_history_adapter()
	_test_real_recruitment_transaction_and_rejection()
	_test_save_file_round_trip_and_old_save()
	_test_chronicle_panel_and_world_hud()
	_complete()


func _state() -> CampaignState:
	return CampaignState.create(GameManager.config(), "Chronicle", 61622)


func _test_empty_and_invalid_events() -> void:
	section("empty campaigns stay empty and rejected events do not write")
	var state := _state()
	equal(CampaignChronicle.count_recorded(state), 0, "a new campaign starts with no events")
	equal(CampaignChronicle.recent(state), [], "an empty campaign returns empty history")
	check(not CampaignChronicle.record(state, "not_a_kind", "Invalid"), "invalid event kinds are refused")
	check(not CampaignChronicle.record(state, "travel", "   "), "blank titles are refused")
	check(not CampaignChronicle.record(null, "travel", "Invalid"), "no campaign rejects writes")
	check(not state.flags.has(CampaignChronicle.STORE_KEY),
		"invalid events do not create a ledger or alter campaign flags")
	check(CampaignChronicle.recent(null).is_empty(), "null campaigns have no history")
	check(CampaignChronicle.recent(state, 0).is_empty(), "a zero limit returns no events")
	state.flags[CampaignChronicle.STORE_KEY] = {"entries": "bad"}
	var previous := state.flags.duplicate(true)
	check(not CampaignChronicle.record(state, "travel", "Cannot overwrite"),
		"malformed existing history is not silently discarded")
	equal(state.flags, previous, "invalid history remains untouched until repaired")


func _test_recorded_order_filters_and_snapshot_safety() -> void:
	section("events are ordered by campaign time and filtered without aliasing")
	var state := _state()
	check(CampaignChronicle.record(state, "travel", "Reached Redmoor",
		"Marched east.", "", "redmoor"), "first journey recorded")
	state.clock.advance_hours(2.0)
	check(CampaignChronicle.record(state, "recruitment", "Alena joined", "Paid 18 gold.",
		"s_0001", "redmoor"), "a named recruit is recorded")
	state.clock.advance_hours(3.0)
	check(CampaignChronicle.record(state, "milestone", "Company founded"), "a milestone is recorded")
	equal(CampaignChronicle.count_recorded(state), 3, "three separate events persisted")
	var latest := CampaignChronicle.recent(state)
	equal(latest.size(), 3, "all events returned")
	equal(latest[0].get("title"), "Company founded", "latest time is first")
	equal(latest[1].get("title"), "Alena joined", "middle time is second")
	equal(latest[2].get("title"), "Reached Redmoor", "earliest time is last")
	equal(CampaignChronicle.recent(state, 1).size(), 1, "limit bounds the output")
	equal(CampaignChronicle.recent(state, 99, "travel").size(), 1, "kind filtering works")
	equal(CampaignChronicle.recent(state, 99, "battle").size(), 0,
		"no battle summary appears before a battle is fought")
	var personal := CampaignChronicle.for_person(state, "s_0001")
	equal(personal.size(), 1, "individual chronicle entries query persistent person IDs")
	equal(personal[0].get("title"), "Alena joined", "person query returns the recruit's record")
	equal(CampaignChronicle.for_person(state, "unknown"), [], "unknown actor returns no events")
	latest[0]["title"] = "Overwritten"
	equal(CampaignChronicle.recent(state)[0].get("title"), "Company founded",
		"caller cannot mutate authoritative log through returned snapshots")
	var data := state.to_dict()
	var restored := CampaignState.from_dict(data, GameManager.config())
	equal(CampaignChronicle.recent(restored), CampaignChronicle.recent(state),
		"the existing flags serializer round-trips ordered history")
	var next_id := str(((state.flags[CampaignChronicle.STORE_KEY] as Dictionary)
		.get("next_id", 0)))
	equal(next_id, "4", "sequence ID advances for the next event")


func _test_battle_history_adapter() -> void:
	section("existing battle history is shown without extra writes")
	var state := _state()
	state.flags["battle_log"] = [
		{"battle_id": "battle_0001", "day": 4, "hour": 17.5,
			"winner": "player", "enemy": "Road Bandits",
			"player_dead": 2, "enemy_dead": 7, "gold": 63},
		{"battle_id": "battle_0002", "day": 5, "hour": 9.0,
			"winner": "retreat", "withdrawal": true, "enemy": "Mercenaries",
			"player_dead": 0, "enemy_dead": 1, "gold": 0},
	]
	var all := CampaignChronicle.recent(state)
	equal(all.size(), 2, "old battle records appear as chronicle events")
	equal(all[0].get("id"), "battle:battle_0002", "latest battle sorts first")
	contains(str(all[0].get("title", "")), "Withdrawal",
		"a retreat is correctly distinguished from victory")
	contains(str(all[1].get("detail", "")), "2 fallen",
		"battle summary uses actual casualty counts")
	equal(CampaignChronicle.count_recorded(state), 0,
		"reading battle results creates no duplicate campaign events")
	equal(CampaignChronicle.recent(state, 99, "recruitment").size(), 0,
		"filtering out battles does not create recruitment events")
	var snapshot := state.flags.duplicate(true)
	var copy := CampaignChronicle.recent(state)
	copy[0]["title"] = "Not real"
	equal(state.flags, snapshot, "battle adapter never mutates the saved battle log")


func _test_real_recruitment_transaction_and_rejection() -> void:
	section("real recruitment records only completed transactions")
	var state := _state()
	var builder := WorldBuilder.new(state, GameManager.config())
	builder.build_if_needed()
	var settlement := state.settlement("greywatch")
	check(settlement != null, "recruitment fixture has a real town")
	if settlement == null:
		return
	state.current_settlement_id = settlement.id
	state.player_gold = 10000
	settlement.recruit_pool["peasant_recruit"] = 3
	var recruitment := RecruitmentService.build(state, GameManager.config())
	check(recruitment != null, "recruitment service built")
	if recruitment == null:
		return
	var accepted := recruitment.recruit(settlement, "peasant_recruit")
	check(bool(accepted.get("ok", false)), "recruitment transaction succeeds")
	if not bool(accepted.get("ok", false)):
		return
	var recruit := accepted.get("soldier") as Soldier
	check(recruit != null, "a real soldier was created")
	equal(CampaignChronicle.count_recorded(state), 1,
		"successful transaction creates exactly one history event")
	var first := CampaignChronicle.recent(state)[0]
	if recruit != null:
		equal(first.get("person_id"), recruit.id, "event refers to persistent soldier ID")
		contains(str(first.get("title", "")), recruit.full_name(), "event has the true recruit name")
	equal(first.get("place_id"), settlement.id, "event captures actual recruitment town")

	var before := CampaignChronicle.count_recorded(state)
	state.current_settlement_id = "not_here"
	var refused := recruitment.recruit(settlement, "peasant_recruit")
	check(not bool(refused.get("ok", false)), "recruiting while away is refused")
	equal(CampaignChronicle.count_recorded(state), before,
		"rejected transactions never write a misleading success event")


func _test_save_file_round_trip_and_old_save() -> void:
	section("chronicle survives the save pipeline without changing save schema")
	SaveManager.delete_all_saves()
	var state := _state()
	state.clock.day = 8
	state.clock.hour = 11.25
	check(CampaignChronicle.record(state, "milestone", "The first contract"),
		"milestone enters the campaign")
	check(SaveManager.save_campaign(state), "campaign saves with the existing save manager")
	var loaded := SaveManager.load_campaign(SaveManager.SLOT_DEFAULT, GameManager.config())
	check(loaded != null, "chronicle campaign reloads from disk")
	if loaded != null:
		equal(CampaignChronicle.recent(loaded).size(), 1, "milestone survives disk persistence")
		equal(CampaignChronicle.recent(loaded)[0].get("title"), "The first contract",
			"stored text comes back intact")
		equal(loaded.clock.day, 8, "recording does not alter campaign time")
		equal(loaded.clock.hour, 11.25, "clock fractional hours are retained")
	var old := state.to_dict()
	old["flags"] = {}
	var from_old := CampaignState.from_dict(old, GameManager.config())
	equal(CampaignChronicle.recent(from_old), [], "old campaigns load with an empty chronicle")
	check(CampaignChronicle.record(from_old, "travel", "First new journey"),
		"an older campaign can start recording events without a migration")
	SaveManager.delete_all_saves()


func _test_chronicle_panel_and_world_hud() -> void:
	section("journal UI receives history but owns no campaign simulation state")
	var state := _state()
	check(CampaignChronicle.record(state, "travel", "Reached Greywatch"),
		"a visible sample is recorded")
	var panel := CampaignChroniclePanel.new()
	runner.add_child(panel)
	panel.set_events(CampaignChronicle.recent(state))
	equal(panel.event_count(), 1, "journal panel receives one presentation snapshot")
	check(panel._rows != null, "journal has a scrolling row container")
	check(panel._rows.get_child_count() > 0, "journal renders an actual event row")
	var stored_day := state.clock.day
	var hud := WorldHud.new()
	runner.add_child(hud)
	hud._state = state
	check(not hud.chronicle_visible(), "chronicle is initially closed")
	hud.toggle_chronicle()
	check(hud.chronicle_visible(), "world HUD opens the chronicle")
	equal(hud._chronicle_panel.event_count(), 1, "opened HUD displays real recorded events")
	hud.toggle_chronicle()
	check(not hud.chronicle_visible(), "a second request closes the chronicle")
	equal(state.clock.day, stored_day, "opening or closing the journal never advances game time")
	hud.free()
	panel.free()
