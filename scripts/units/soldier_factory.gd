class_name SoldierFactory
extends RefCounted
## Creates a new [Soldier] from a unit archetype.
##
## Everything a recruit starts with - name, age, traits, morale, loyalty, hit
## points - is decided here, and only here. The factory does not touch the
## campaign: it returns a soldier and the caller decides whether to keep it, which
## keeps "roll up a person" and "charge gold for them" separate concerns.

var state: CampaignState = null
var config: GameConfig = null
var units: UnitCatalog = null
var traits: TraitCatalog = null
var names: NameGenerator = null


func _init(p_state: CampaignState, p_config: GameConfig) -> void:
	state = p_state
	config = p_config


## Loads the catalogs from data. Returns null when the state/config are unusable.
static func build(p_state: CampaignState, p_config: GameConfig) -> SoldierFactory:
	if p_state == null or p_config == null:
		return null
	var factory := SoldierFactory.new(p_state, p_config)
	factory.units = UnitCatalog.load_from()
	factory.traits = TraitCatalog.load_from()
	factory.names = NameGenerator.load_from(p_state.rng)
	return factory


## Create one soldier. Returns
## [code]{"ok": bool, "reason": String, "soldier": Soldier}[/code].
## The soldier is NOT added to the campaign - call [method CampaignState.register_soldier].
func create(unit_type_id: String, index: int, location_name: String = "") -> Dictionary:
	var definition := units.get_definition(unit_type_id)
	if definition == null:
		return {"ok": false, "reason": "unknown unit type '%s'" % unit_type_id, "soldier": null}

	var soldier := Soldier.new()
	soldier.unit_type_id = definition.id
	soldier.faction_id = state.player_party.faction_id if state.player_party != null else ""

	var rolled_name := names.name_for(index, _taken_names())
	soldier.first_name = str(rolled_name.get("first_name", "Unnamed"))
	soldier.surname = str(rolled_name.get("surname", ""))
	soldier.age = names.value_for(
		index, "age",
		config.get_int("recruitment.min_age", 17),
		config.get_int("recruitment.max_age", 33)
	)

	var trait_ids := roll_traits(index)
	for trait_id in trait_ids:
		soldier.add_trait(trait_id)

	soldier.level = 1
	soldier.xp = 0
	soldier.morale = clampi(
		config.get_int("recruitment.base_morale", 60) + int(traits.total_modifier(trait_ids, "morale")),
		0, 100
	)
	soldier.loyalty = clampi(
		config.get_int("recruitment.base_loyalty", 50) + int(traits.total_modifier(trait_ids, "loyalty")),
		0, 100
	)

	var hit_points := float(definition.max_hp_at(1, config))
	hit_points *= 1.0 + (traits.total_modifier(trait_ids, "hp_pct") / 100.0)
	soldier.max_hp = maxi(1, int(round(hit_points)))
	soldier.hp = soldier.max_hp

	var where := location_name if not location_name.is_empty() else "the road"
	var day := state.clock.day if state.clock != null else 1
	soldier.record_history(day, "recruited", "Swore service at %s." % where)

	return {"ok": true, "reason": "", "soldier": soldier}


## Trait ids for a recruit: one or two, negative traits at the configured chance.
func roll_traits(index: int) -> Array[String]:
	var out: Array[String] = []
	var count := names.value_for(
		index, "trait_count",
		config.get_int("progression.trait_rolls_min", 1),
		config.get_int("progression.trait_rolls_max", 2)
	)
	var negative_pool := traits.ids_with_polarity("negative")
	var positive_pool := traits.ids_with_polarity("positive")
	var neutral_pool := traits.ids_with_polarity("neutral")
	var negative_chance := config.get_float("progression.negative_trait_chance", 0.35)

	for slot in count:
		var generator := state.rng.stream("trait:%d:%d" % [index, slot])
		var pool: Array[String] = []
		if generator.randf() < negative_chance and not negative_pool.is_empty():
			pool.append_array(negative_pool)
		else:
			pool.append_array(positive_pool)
			pool.append_array(neutral_pool)
		if pool.is_empty():
			continue
		var picked := pool[generator.randi_range(0, pool.size() - 1)]
		if not out.has(picked):
			out.append(picked)
	return out


## Full names already in the world, so a new recruit is not a duplicate.
func _taken_names() -> Dictionary:
	var taken := {}
	for key in state.soldiers.keys():
		var soldier := state.soldiers[key] as Soldier
		if soldier != null:
			taken[soldier.full_name()] = true
	return taken
