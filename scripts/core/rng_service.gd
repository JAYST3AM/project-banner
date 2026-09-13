class_name RngService
extends RefCounted
## Deterministic random-number source for a campaign.
##
## A campaign is identified by a single integer seed. Every subsystem asks the
## service for its own named stream ([code]rng.stream("bandit_spawns")[/code])
## so one system consuming randomness can never shift another system's results.
##
## Seeds are derived with a hand-written FNV-1a hash instead of Godot's built-in
## [method @GlobalScope.hash], because the built-in hash is not guaranteed to be
## stable across engine versions - and a campaign seed that changes meaning after
## an engine upgrade would silently rewrite a player's world.

var root_seed: int = 0


func _init(p_root_seed: int = 0) -> void:
	root_seed = p_root_seed


## Deterministic 32-bit FNV-1a hash of a string.
static func stable_hash(text: String) -> int:
	var h: int = 0x811c9dc5
	for byte in text.to_utf8_buffer():
		h = h ^ int(byte)
		h = (h * 0x01000193) & 0xFFFFFFFF
	return h


## A fresh, deterministically-seeded generator for the given stream name.
## Two calls with the same name return generators at the same state.
func stream(name: String) -> RandomNumberGenerator:
	var rng := RandomNumberGenerator.new()
	rng.seed = derive_seed(name)
	return rng


func derive_seed(name: String) -> int:
	return stable_hash("%d::%s" % [root_seed, name])


func randf(name: String) -> float:
	return stream(name).randf()


func randi_range(name: String, from: int, to: int) -> int:
	return stream(name).randi_range(from, to)


## Stable pick from an array, independent of array iteration order.
func pick(name: String, options: Array) -> Variant:
	if options.is_empty():
		return null
	var idx: int = int(stream(name).randi() % options.size())
	return options[idx]
