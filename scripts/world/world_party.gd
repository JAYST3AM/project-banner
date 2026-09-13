class_name WorldParty
extends RefCounted
## A party that moves around the overworld (everything except the player).
##
## Deliberately generic: bandits, caravans, patrols and lord armies all use this
## one record, differing only by [member kind], [member behaviour] and which
## [Party] of soldiers they point at.

const BEHAVIOUR_STATIONARY := "stationary"
const BEHAVIOUR_WANDER := "wander"
const BEHAVIOUR_PATROL := "patrol"

var id: String = ""
## Links to the soldiers that make up this party (see CampaignState.parties).
var party_id: String = ""
var display_name: String = ""
var kind: String = Party.KIND_BANDIT
var behaviour: String = BEHAVIOUR_WANDER

var position: Vector2 = Vector2.ZERO
var home_position: Vector2 = Vector2.ZERO
var wander_radius: float = 120.0
var destination: Vector2 = Vector2.ZERO

## Game hours of "leave me alone" applied after the player retreats from this party.
var encounter_cooldown_until_hours: float = 0.0
## Set once this party has been destroyed in battle.
var defeated: bool = false
## Increments each time the party picks a new wander target. Persisted so wander
## destinations stay deterministic across a save/load without storing an RNG.
var wander_count: int = 0


func is_available() -> bool:
	return not defeated


func to_dict() -> Dictionary:
	return {
		"id": id,
		"party_id": party_id,
		"display_name": display_name,
		"kind": kind,
		"behaviour": behaviour,
		"position": [position.x, position.y],
		"home_position": [home_position.x, home_position.y],
		"wander_radius": wander_radius,
		"destination": [destination.x, destination.y],
		"encounter_cooldown_until_hours": encounter_cooldown_until_hours,
		"defeated": defeated,
		"wander_count": wander_count,
	}


static func from_dict(data: Dictionary) -> WorldParty:
	var w := WorldParty.new()
	w.id = str(data.get("id", ""))
	w.party_id = str(data.get("party_id", ""))
	w.display_name = str(data.get("display_name", "Unknown Party"))
	w.kind = str(data.get("kind", Party.KIND_BANDIT))
	w.behaviour = str(data.get("behaviour", BEHAVIOUR_WANDER))
	w.position = DataUtils.vec2_from(data.get("position", [0.0, 0.0]))
	w.home_position = DataUtils.vec2_from(data.get("home_position", [w.position.x, w.position.y]))
	w.wander_radius = float(data.get("wander_radius", 120.0))
	w.destination = DataUtils.vec2_from(data.get("destination", [w.position.x, w.position.y]))
	w.encounter_cooldown_until_hours = float(data.get("encounter_cooldown_until_hours", 0.0))
	w.defeated = bool(data.get("defeated", false))
	w.wander_count = int(data.get("wander_count", 0))
	return w
