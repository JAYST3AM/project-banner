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

## Player-issued move order, if any. Cleared when the unit reaches it.
var move_order: Vector2 = Vector2.ZERO
var has_move_order: bool = false
## Player-issued attack order: a unit id to hunt, or -1. Cleared when it dies.
var attack_order_target_id: int = -1


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
