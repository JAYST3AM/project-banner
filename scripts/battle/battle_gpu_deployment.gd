class_name BattleGpuDeployment
extends RefCounted
## Deterministic, transactional legal deployment on the live battlefield.
## No second terrain generation; never change soldier positions if any
## living soldier cannot find a legal, sufficiently separated landing point.
const CLEARANCE := 0.45
const MIN_GAP := 0.90


static func _clear(mask: PackedInt32Array, point: Vector2) -> bool:
	for dx in [-CLEARANCE, CLEARANCE]:
		for dy in [-CLEARANCE, CLEARANCE]:
			if BattleTerrainGpuMask.is_blocked(mask, point + Vector2(dx, dy)):
				return false
	return not BattleTerrainGpuMask.is_blocked(mask, point)


static func _separated(point: Vector2, claimed: PackedVector2Array) -> bool:
	for other in claimed:
		if point.distance_squared_to(other) < MIN_GAP * MIN_GAP:
			return false
	return true


## Result has ok/positions/repaired/reason. Never writes input units.
## Zones come from the SAME BattleSetup deployment rectangles used to clear
## the production terrain for deployment. Search order and tie-breaking are
## row-major deterministic and use no random stream.
static func plan(terrain: BattlefieldTerrain, units: Array[BattleUnit],
		zones: Array[Rect2]) -> Dictionary:
	var result := {"ok": false, "reason": "", "positions": PackedVector2Array(),
		"repaired": 0}
	if terrain == null or not terrain.is_valid() or zones.size() != 2:
		result["reason"] = "missing terrain or deployment zones"
		return result
	var mask := BattleTerrainGpuMask.from_terrain(terrain)
	if mask[3] != 1:
		result["reason"] = "terrain mask was not enabled"
		return result
	var claimed := PackedVector2Array()
	var positions := PackedVector2Array()
	var repaired := 0
	for unit in units:
		if unit == null:
			result["reason"] = "null battle unit"
			return result
		if not unit.is_alive():
			positions.append(unit.position)
			continue
		var side_index := 0 if unit.side == BattleContext.SIDE_PLAYER else 1
		var zone := zones[side_index]
		var selected := unit.position
		var legal := zone.has_point(selected) and _clear(mask, selected) and \
			_separated(selected, claimed)
		if not legal:
			var best_distance := INF
			var found := false
			for row in terrain.rows:
				for col in terrain.cols:
					var candidate := Vector2((float(col) + 0.5) * terrain.cell_size,
						(float(row) + 0.5) * terrain.cell_size)
					if not zone.has_point(candidate) or not _clear(mask, candidate) or \
							not _separated(candidate, claimed):
						continue
					var d := candidate.distance_squared_to(unit.position)
					if not found or d < best_distance:
						found = true
						best_distance = d
						selected = candidate
			if not found:
				result["reason"] = "no legal cell for soldier %d" % unit.id
				return result
			repaired += 1
		claimed.append(selected)
		positions.append(selected)
	result["ok"] = true
	result["positions"] = positions
	result["repaired"] = repaired
	return result


## Apply only a fully valid plan. This is called BEFORE formations are created.
static func apply(plan_result: Dictionary, units: Array[BattleUnit]) -> bool:
	if not bool(plan_result.get("ok", false)):
		return false
	var positions: PackedVector2Array = plan_result.get("positions", PackedVector2Array())
	if positions.size() != units.size():
		return false
	for i in units.size():
		units[i].position = positions[i]
	return true
