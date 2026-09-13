class_name DataUtils
extends RefCounted
## Small JSON <-> Godot type conversions shared by every serialisable class.
##
## Kept dependency-free on purpose: data classes (Soldier, Settlement, ...) call
## into this instead of into each other, which keeps the class-reference graph a
## tree rather than a cycle.

const VERSION_SAVE := "save_version"


static func vec2_from(raw: Variant, fallback: Vector2 = Vector2.ZERO) -> Vector2:
	if typeof(raw) == TYPE_ARRAY:
		var arr := raw as Array
		if arr.size() >= 2:
			return Vector2(float(arr[0]), float(arr[1]))
		return fallback
	if typeof(raw) == TYPE_DICTIONARY:
		var d := raw as Dictionary
		return Vector2(float(d.get("x", fallback.x)), float(d.get("y", fallback.y)))
	return fallback


static func vec2_to(value: Vector2) -> Array:
	return [value.x, value.y]


static func string_array(raw: Variant) -> Array[String]:
	var out: Array[String] = []
	if typeof(raw) == TYPE_ARRAY:
		for item in raw as Array:
			out.append(str(item))
	return out


static func int_keys_dict(raw: Variant) -> Dictionary:
	var out := {}
	if typeof(raw) != TYPE_DICTIONARY:
		return out
	for key in (raw as Dictionary).keys():
		out[str(key)] = int((raw as Dictionary)[key])
	return out


## "Day 3 - 14:20" style suffix used by history entries.
static func timestamp(day: int, hour: float) -> String:
	var h := int(floor(hour))
	var m := int(floor((hour - float(h)) * 60.0))
	return "Day %d, %02d:%02d" % [day, clampi(h, 0, 23), clampi(m, 0, 59)]
