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
## A trader on a route: movement belongs to CaravanService, not to the overworld's wander step
## (D-139). The overworld skips this behaviour so two services never fight over one position.
const BEHAVIOUR_TRADE := "trade"

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

## ---------- caravans (D-139): only meaningful when kind is "caravan" ----------
## The town it is trading out of, and the town it is carrying its cargo to. Empty to_settlement_id
## means it is between legs and will plan one on the next step.
var from_settlement_id: String = ""
var to_settlement_id: String = ""
## What it carries, by good id, priced by TradeService.
var cargo: Array[String] = []
## The towns of the current leg's route, in order: [from, ...via..., to]. Empty when between legs.
var path_stops: Array[String] = []
## Which leg of [member path_stops] the caravan is walking: from stops[leg_index] to the next.
var leg_index: int = 0
## How far along the current leg's curve it has walked, in world units.
var route_walked: float = 0.0
## Completed deliveries, which also seeds the next route's RNG stream.
var trips: int = 0
## Whether the current stuck-with-no-work episode has been logged (so it is logged once, not per step).
var idle_warned: bool = false


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
		"from_settlement_id": from_settlement_id,
		"to_settlement_id": to_settlement_id,
		"cargo": cargo.duplicate(),
		"path_stops": path_stops.duplicate(),
		"leg_index": leg_index,
		"route_walked": route_walked,
		"trips": trips,
		"idle_warned": idle_warned,
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
	w.from_settlement_id = str(data.get("from_settlement_id", ""))
	w.to_settlement_id = str(data.get("to_settlement_id", ""))
	for good_any in (data.get("cargo", []) as Array):
		w.cargo.append(str(good_any))
	for stop_any in (data.get("path_stops", []) as Array):
		w.path_stops.append(str(stop_any))
	w.leg_index = int(data.get("leg_index", 0))
	w.route_walked = float(data.get("route_walked", 0.0))
	w.trips = int(data.get("trips", 0))
	w.idle_warned = bool(data.get("idle_warned", false))
	return w
