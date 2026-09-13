class_name CampaignState
extends RefCounted
## The persistent state of one campaign.
##
## Ownership rules (see docs/GAME_ARCHITECTURE.md):
## [br]- [b]Soldiers[/b]: owned here, in [member soldiers], keyed by soldier id.
##   Parties only store ids. Nothing else may own a soldier.
## [br]- [b]Settlements[/b]: owned here in [member settlements].
## [br]- [b]Parties[/b]: the player's party is [member player_party]; every other
##   party lives in [member parties].
## [br]- [b]Time[/b]: owned by [member clock].
##
## Every field is either a plain JSON-safe value or a class with
## [code]to_dict()[/code] / [code]from_dict()[/code], so saving is deliberately boring.

const SCHEMA_VERSION := 2

var campaign_id: String = ""
var campaign_name: String = ""
var campaign_seed: int = 0
var created_at: String = ""
var last_saved_at: String = ""

var clock: CampaignClock = null
var rng: RngService = null

var player_gold: int = 0
var player_party: Party = null

var world_position: Vector2 = Vector2.ZERO
var current_settlement_id: String = ""
var destination_id: String = ""

## soldier_id -> Soldier (every soldier in the world, alive or dead)
var soldiers: Dictionary = {}
## settlement_id -> Settlement
var settlements: Dictionary = {}
## Connections between settlements: [{"a": id, "b": id, "kind": "road"|"track"}]
var roads: Array[Dictionary] = []
## party_id -> WorldParty (overworld representation of every non-player party)
var parties: Dictionary = {}
## party_id -> Party (enemy/other parties' soldier rosters, keyed like [member parties])
var enemy_parties: Dictionary = {}
## Arbitrary future-proof extension bag.
var flags: Dictionary = {}

var _next_soldier_index: int = 1
var _config: GameConfig = null


func _init(config: GameConfig = null) -> void:
	_config = config


## ---------- construction -------------------------------------------------

static func create(p_config: GameConfig, campaign_name: String, seed_value: int) -> CampaignState:
	var state := CampaignState.new(p_config)
	state.campaign_name = campaign_name
	state.campaign_seed = seed_value
	state.rng = RngService.new(seed_value)
	state.clock = CampaignClock.new(p_config)
	state.clock.day = p_config.get_int("time.starting_day", 1)
	state.clock.hour = p_config.get_float("time.starting_hour", 8.0)
	state.clock.set_speed_by_name(p_config.get_string("time.default_speed", "normal"))
	state.player_gold = p_config.get_int("campaign.starting_gold", 250)
	state.player_party = Party.new()
	state.player_party.id = "player_party"
	state.player_party.kind = Party.KIND_PLAYER
	state.player_party.display_name = p_config.get_string("campaign.player_party_name", "The Banner")
	state.player_party.faction_id = p_config.get_string("campaign.starting_faction_id", "free_companies")
	return state


## ---------- soldier registry --------------------------------------------

func next_soldier_id() -> String:
	var candidate := ""
	while true:
		candidate = "s_%04d" % _next_soldier_index
		_next_soldier_index += 1
		if not soldiers.has(candidate):
			return candidate
	return candidate


## The index the next generated soldier id will use, without consuming it.
## Name generation keys off this so a soldier's name is deterministic and needs
## no stored generator state.
func peek_soldier_index() -> int:
	return _next_soldier_index


func register_soldier(soldier: Soldier) -> void:
	if soldier == null:
		return
	if soldier.id.is_empty():
		soldier.id = next_soldier_id()
	soldiers[soldier.id] = soldier
	_track_soldier_index(soldier.id)


func soldier(soldier_id: String) -> Soldier:
	return soldiers.get(soldier_id, null) as Soldier


## All members of a party as soldier objects, in membership order.
func party_members(party: Party) -> Array[Soldier]:
	var out: Array[Soldier] = []
	if party == null:
		return out
	for sid in party.member_ids:
		var s := soldier(sid)
		if s != null:
			out.append(s)
	return out


func active_members(party: Party) -> Array[Soldier]:
	var out: Array[Soldier] = []
	for s in party_members(party):
		if s.is_alive() and s.is_active():
			out.append(s)
	return out


## How many soldiers are alive and fit to take the field.
##
## [b]This - not [method Party.size] - is what travel pace, encounter strength,
## party capacity and every "how strong is this party" display must use.[/b] A
## party keeps its dead for the historical record, so the two numbers diverge the
## moment anyone dies, and using the roster count where the force count is meant
## makes casualties free.
func active_member_count(party: Party) -> int:
	if party == null:
		return 0
	var count := 0
	for soldier_id in party.member_ids:
		var s := soldier(soldier_id)
		if s != null and s.is_alive() and s.is_active():
			count += 1
	return count


## Everyone who has ever belonged to this party, including the dead. This is the
## historical record the roster screen lists; it is not a measure of strength.
func roster_member_count(party: Party) -> int:
	return party.size() if party != null else 0


## How many of this party's members have died. Surfaced separately so the UI can
## show casualties without conflating them with the active force.
func fallen_member_count(party: Party) -> int:
	if party == null:
		return 0
	var count := 0
	for soldier_id in party.member_ids:
		var s := soldier(soldier_id)
		if s != null and not s.is_alive():
			count += 1
	return count


func fallen_members(party: Party) -> Array[Soldier]:
	var out: Array[Soldier] = []
	for s in party_members(party):
		if not s.is_alive():
			out.append(s)
	return out


func soldiers_with_status(status: String) -> Array[Soldier]:
	var out: Array[Soldier] = []
	for key in soldiers.keys():
		var s := soldiers[key] as Soldier
		if s != null and s.status == status:
			out.append(s)
	return out


func _track_soldier_index(soldier_id: String) -> void:
	# Keep generated ids monotonic so ids are never reused after a load.
	var digits := soldier_id.trim_prefix("s_")
	if digits.is_valid_int():
		_next_soldier_index = maxi(_next_soldier_index, int(digits) + 1)


## ---------- territory / parties -----------------------------------------

func settlement(settlement_id: String) -> Settlement:
	return settlements.get(settlement_id, null) as Settlement


func world_party(party_id: String) -> WorldParty:
	return parties.get(party_id, null) as WorldParty


func party_of(world_party: WorldParty) -> Party:
	if world_party == null:
		return null
	return enemy_parties.get(world_party.party_id, null) as Party


func destination_name() -> String:
	if destination_id.is_empty():
		return "None"
	var s := settlement(destination_id)
	if s == null:
		return destination_id
	return s.name


## Coarse "army strength" number used by the encounter prompt.
## Based on effective hit points and veterancy, so it grows with both recruits
## and experience without needing combat maths here.
func party_strength(party: Party) -> int:
	var total := 0.0
	for s in active_members(party):
		total += float(s.max_hp) * (1.0 + 0.15 * float(s.level - 1))
	return int(round(total))


## ---------- serialisation ----------------------------------------------

func to_dict() -> Dictionary:
	var soldier_data := {}
	for key in soldiers.keys():
		var s := soldiers[key] as Soldier
		if s != null:
			soldier_data[key] = s.to_dict()
	var settlement_data := {}
	for key in settlements.keys():
		var st := settlements[key] as Settlement
		if st != null:
			settlement_data[key] = st.to_dict()
	var world_party_data := {}
	for key in parties.keys():
		var wp := parties[key] as WorldParty
		if wp != null:
			world_party_data[key] = wp.to_dict()
	var enemy_party_data := {}
	for key in enemy_parties.keys():
		var ep := enemy_parties[key] as Party
		if ep != null:
			enemy_party_data[key] = ep.to_dict()
	return {
		"campaign_id": campaign_id,
		"campaign_name": campaign_name,
		"campaign_seed": campaign_seed,
		"created_at": created_at,
		"last_saved_at": last_saved_at,
		"clock": clock.to_dict() if clock != null else {},
		"player_gold": player_gold,
		"player_party": player_party.to_dict() if player_party != null else {},
		"world_position": DataUtils.vec2_to(world_position),
		"current_settlement_id": current_settlement_id,
		"destination_id": destination_id,
		"soldiers": soldier_data,
		"settlements": settlement_data,
		"roads": roads.duplicate(true),
		"parties": world_party_data,
		"enemy_parties": enemy_party_data,
		"flags": flags.duplicate(true),
		"next_soldier_index": _next_soldier_index,
	}


static func from_dict(data: Dictionary, config: GameConfig) -> CampaignState:
	var state := CampaignState.new(config)
	state.campaign_id = str(data.get("campaign_id", ""))
	state.campaign_name = str(data.get("campaign_name", "Unnamed Campaign"))
	state.campaign_seed = int(data.get("campaign_seed", 0))
	state.created_at = str(data.get("created_at", ""))
	state.last_saved_at = str(data.get("last_saved_at", ""))
	state.player_gold = int(data.get("player_gold", 0))
	state.world_position = DataUtils.vec2_from(data.get("world_position", [0.0, 0.0]))
	state.current_settlement_id = str(data.get("current_settlement_id", ""))
	state.destination_id = str(data.get("destination_id", ""))
	state.flags = (data.get("flags", {}) as Dictionary).duplicate(true)
	state._next_soldier_index = int(data.get("next_soldier_index", 1))

	state.rng = RngService.new(state.campaign_seed)
	state.clock = CampaignClock.new(config)
	state.clock.from_dict(data.get("clock", {}) as Dictionary)
	state.player_party = Party.from_dict(data.get("player_party", {}) as Dictionary)

	for key in (data.get("soldiers", {}) as Dictionary).keys():
		var raw: Variant = (data["soldiers"] as Dictionary)[key]
		if typeof(raw) != TYPE_DICTIONARY:
			continue
		var s := Soldier.from_dict(raw as Dictionary)
		if s.id.is_empty():
			s.id = str(key)
		state.soldiers[s.id] = s
		state._track_soldier_index(s.id)

	state.settlements.clear()
	for key in (data.get("settlements", {}) as Dictionary).keys():
		var raw_settlement: Variant = (data["settlements"] as Dictionary)[key]
		if typeof(raw_settlement) == TYPE_DICTIONARY:
			state.settlements[str(key)] = Settlement.from_dict(raw_settlement as Dictionary)

	state.roads.clear()
	for raw_road in data.get("roads", []) as Array:
		if typeof(raw_road) == TYPE_DICTIONARY:
			state.roads.append((raw_road as Dictionary).duplicate(true))

	state.parties.clear()
	for key in (data.get("parties", {}) as Dictionary).keys():
		var raw_party: Variant = (data["parties"] as Dictionary)[key]
		if typeof(raw_party) == TYPE_DICTIONARY:
			state.parties[str(key)] = WorldParty.from_dict(raw_party as Dictionary)

	state.enemy_parties.clear()
	for key in (data.get("enemy_parties", {}) as Dictionary).keys():
		var raw_enemy: Variant = (data["enemy_parties"] as Dictionary)[key]
		if typeof(raw_enemy) == TYPE_DICTIONARY:
			state.enemy_parties[str(key)] = Party.from_dict(raw_enemy as Dictionary)

	return state


func config() -> GameConfig:
	return _config


func set_config(p_config: GameConfig) -> void:
	_config = p_config
	if clock != null:
		clock.config = p_config
		clock.apply_config()
