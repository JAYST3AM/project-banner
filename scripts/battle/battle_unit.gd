class_name BattleUnit
extends RefCounted
## One fighting body on a battlefield.
##
## A [BattleUnit] is a *view of* a [Soldier] for the duration of one battle: it
## carries the soldier's id so the outcome can be written back to the right person,
## and it carries its own hit points, position and target so the fight can be
## simulated without touching campaign data. Nothing here is ever the only copy
## of anything persistent.

var id: int = -1
## The persistent person this unit represents. Never empty.
var soldier_id: String = ""
var side: String = BattleContext.SIDE_PLAYER

var display_name: String = ""
var unit_type_id: String = ""
var unit_name: String = ""
var level: int = 1
var traits: Array[String] = []

var max_hp: int = 1
var hp: int = 1
var attack: int = 1
var defence: int = 0
var move_speed: float = 5.0
var attack_range: float = 1.0
var attack_cooldown: float = 1.0
var ranged: bool = false

var position: Vector2 = Vector2.ZERO
var facing: Vector2 = Vector2.RIGHT

var alive: bool = true
var kills: int = 0
var damage_dealt: int = 0
var damage_taken: int = 0

## Seconds until this unit may strike again.
var cooldown_left: float = 0.0
## Set when this unit is killed, so the result can name the killer.
var killed_by_id: int = -1

## Who last struck this soldier, and on which tick. Set by the damage step, read by the
## formation-driven gate: a soldier being hit may retaliate against the soldier who hit it
## without being allowed to search for anybody. This is what keeps a flanked or rear-attacked
## soldier from standing still while its formation watches the other way. See D-105.
var last_attacker_id: int = -1
var last_attacked_tick: int = -1

## Player-issued move order, if any. Cleared when the unit reaches it.
var move_order: Vector2 = Vector2.ZERO
var has_move_order: bool = false
## Player-issued attack order: a unit id to hunt, or -1. Cleared when it dies.
var attack_order_target_id: int = -1

## The last simulation tick this soldier was counted into a formation's summary, used as a
## claim stamp and nothing else. The summary pass counts a soldier into its body from the
## body's own roll, then walks the army for the soldiers nobody counted - and this is how it
## knows which are which. It exists so that a soldier detached from a body cannot become
## invisible to the focus layer, and it is never read by gameplay. See D-089.
var summary_tick: int = -1

## ---------- battle-transient target state (Step 7.4) ------------------------
##
## [b]None of this is saved, and none of it belongs to a soldier.[/b] A [BattleUnit]
## exists for the duration of one battle and is rebuilt from the campaign every time, so
## these fields are scratch space for the fight in progress rather than anything
## persistent. A campaign save never sees them, and a battle that is re-run from the same
## seed rebuilds them identically.
##
## They are held as plain ids and counters rather than as node references, timers,
## dictionaries or signals, because a battle of twenty thousand soldiers pays for every
## one of them twenty thousand times: an integer compare is what a target check can
## afford to be, and anything with an allocation behind it is not.

## The enemy this soldier last chose for itself, or -1. An explicit order is not written
## here - orders are the player's and live in [member attack_order_target_id].
var auto_target_id: int = -1

## The simulation tick at which this soldier's next scheduled awareness search is due.
##
## An integer simulation tick rather than a clock of any kind: the schedule has to be
## reproducible from the battle seed, the roster and the orders, and no wall-clock
## reading can promise that. See D-080.
var next_search_tick: int = 0

## How far this soldier looks for its own enemies, in world units, or zero to use
## whatever the battle is configured with. A capability rather than a weapon: it exists so
## that a unit which one day sees further can say so, instead of the search being
## rewritten around what it is carrying.
var awareness_radius: float = 0.0

## The tick at which this soldier last lost an opponent, so that acquisition latency can be
## measured: stamped when a memory is invalidated, read when the next one is stored, and
## the difference in ticks is the answer. Development-only - written and read behind the
## simulator's profiling switch - and battle-transient like everything else here.
var target_lost_tick: int = -1

## Whether the formation-driven gate let this soldier search for an opponent on its last
## awareness tick. Written once per soldier per cadence, and only ever read to count: the
## gate itself decides from the body's geometry, not from this flag.
var fdr_promoted: bool = false

## The formation this soldier belongs to, if any, and the place in it the soldier
## stands.
##
## Held as a direct reference rather than looked up by id: a formed soldier asks for
## its place every step, and a string-keyed dictionary probe there would be paid
## millions of times in a large battle. Both are battle-local objects, so there is no
## ownership question and nothing here ever reaches the campaign.
var formation_ref: BattleFormation = null
var slot_index: int = -1


## Whether this soldier is fighting as part of a formed body.
func is_formed() -> bool:
	return formation_ref != null and slot_index >= 0


## The place this soldier has been told to stand, or its current position when it is
## not in a formation.
func formation_slot() -> Vector2:
	if not is_formed():
		return position
	var slots := formation_ref.slots
	if slot_index >= slots.size():
		return position
	return slots[slot_index]



static func from_snapshot(snapshot: Dictionary, side: String, id: int) -> BattleUnit:
	var unit := BattleUnit.new()
	unit.id = id
	unit.side = side
	unit.soldier_id = str(snapshot.get("soldier_id", ""))
	unit.display_name = str(snapshot.get("name", "Soldier"))
	unit.unit_type_id = str(snapshot.get("unit_type_id", ""))
	unit.unit_name = str(snapshot.get("unit_name", unit.unit_type_id))
	unit.level = int(snapshot.get("level", 1))
	unit.traits = DataUtils.string_array(snapshot.get("traits", []))
	unit.max_hp = maxi(1, int(snapshot.get("max_hp", 1)))
	unit.hp = clampi(int(snapshot.get("hp", unit.max_hp)), 0, unit.max_hp)
	unit.attack = maxi(0, int(snapshot.get("attack", 1)))
	unit.defence = maxi(0, int(snapshot.get("defence", 0)))
	unit.move_speed = maxf(0.1, float(snapshot.get("move_speed", 5.0)))
	unit.attack_range = maxf(0.1, float(snapshot.get("attack_range", 1.0)))
	unit.attack_cooldown = maxf(0.05, float(snapshot.get("attack_cooldown", 1.0)))
	unit.ranged = bool(snapshot.get("ranged", false))
	unit.alive = unit.hp > 0
	return unit


func is_alive() -> bool:
	return alive and hp > 0


func hp_ratio() -> float:
	if max_hp <= 0:
		return 0.0
	return clampf(float(hp) / float(max_hp), 0.0, 1.0)


func is_enemy_of(other: BattleUnit) -> bool:
	return other != null and other.side != side


## Player-issued orders are drawn differently in the view, so this is worth naming.
func has_orders() -> bool:
	return has_move_order or attack_order_target_id >= 0


func clear_orders() -> void:
	has_move_order = false
	move_order = Vector2.ZERO
	attack_order_target_id = -1


## Applies damage. Returns true when this blow was the killing one.
func take_damage(amount: int, attacker_id: int) -> bool:
	var applied := maxi(1, amount)
	hp -= applied
	damage_taken += applied
	if hp <= 0:
		hp = 0
		alive = false
		killed_by_id = attacker_id
		return true
	return false


func describe() -> String:
	return "%s (%s, Lv%d, %s) %d/%d HP" % [
		display_name, unit_name, level, "alive" if is_alive() else "down", hp, max_hp,
	]
