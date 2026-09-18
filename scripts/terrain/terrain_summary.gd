class_name TerrainSummary
extends RefCounted
## What a body of men needs to know about the ground it is standing on, in one object.
##
## This is the terrain's answer to a formation, and it is deliberately a *summary* rather than a pile
## of queries: a formation covering twenty cells asks twenty questions if it reads the field cell by
## cell, and one if it reads this. It is built from the cached maps, so grading a body is a walk over
## the few cells it covers and nothing more.
##
## [b]What it is for.[/b] The tactical layer wants to know whether it is attacking uphill, whether the
## ground under it will hold a line, and whether there is anywhere to hide. None of those are per-cell
## questions, and a formation that has to ask them per soldier would put a terrain query in the
## hottest loop in the game. So the grunt work happens once per body per tick, here, and the soldiers
## keep reading the one array read they already read.
##
## [b]What it is not.[/b] It is not a pathfinder and it does not decide anything. The milestone that
## makes formations *manoeuvre* around bad ground is a later one; this is the information it will
## manoeuvre with.

## Cells the summary was actually taken over. Zero means the rectangle was off the field.
var cells: int = 0
## Mean rise over run across the ground, 0 flat. 1.0 is forty-five degrees.
var mean_slope: float = 0.0
## Mean movement multiplier: how fast a body crosses this ground compared with open ground.
var mean_movement: float = 1.0
## What share of the ground a formation may stand on at all.
var traversable_fraction: float = 1.0
var mean_cover: float = 0.0
var mean_vegetation: float = 0.0
var mean_wetness: float = 0.0
## Cells carrying an obstruction - ground or prop.
var blocked_cells: int = 0
var lowest_height: float = 0.0
var highest_height: float = 0.0
## Which way the ground rises, from the lowest corner to the highest. Zero on level ground.
var uphill: Vector2 = Vector2.ZERO
## The worst slope anywhere in the rectangle, for the "can we hold this" question.
var worst_slope: float = 0.0
## The type covering most of the rectangle - what a commander would call the ground.
var dominant_type: String = ""


## Grade the ground a rectangle covers. Cheap by construction: the rectangle is clamped to the field
## and only the cells inside it are visited.
static func grade(terrain: BattlefieldTerrain, rect: Rect2) -> TerrainSummary:
	var summary := TerrainSummary.new()
	if terrain == null or not terrain.is_valid():
		return summary
	var clipped := rect.intersection(Rect2(Vector2.ZERO, terrain.size))
	if clipped.size.x <= 0.0 or clipped.size.y <= 0.0:
		return summary
	var min_col := terrain.cell_col_at(clipped.position)
	var max_col := terrain.cell_col_at(clipped.position + clipped.size - Vector2(0.01, 0.01))
	var min_row := terrain.cell_row_at(clipped.position)
	var max_row := terrain.cell_row_at(clipped.position + clipped.size - Vector2(0.01, 0.01))
	var type_counts := {}
	var lowest_point := Vector2.ZERO
	var highest_point := Vector2.ZERO
	summary.lowest_height = INF
	summary.highest_height = -INF
	for row in range(min_row, max_row + 1):
		for col in range(min_col, max_col + 1):
			var index := row * terrain.cols + col
			if index < 0 or index >= terrain.cell_count():
				continue
			summary.cells += 1
			summary.mean_slope += terrain.slope_of_cell(index)
			summary.mean_movement += terrain.move_multiplier_of_cell(index)
			summary.mean_cover += terrain.cover_of_cell(index)
			summary.mean_vegetation += terrain.vegetation_of_cell(index)
			summary.mean_wetness += terrain.wetness_of_cell(index)
			summary.worst_slope = maxf(summary.worst_slope, terrain.slope_of_cell(index))
			if not terrain.is_cell_traversable(index):
				summary.blocked_cells += 1
			var height := terrain.height_of_cell(index)
			if height < summary.lowest_height:
				summary.lowest_height = height
				lowest_point = terrain.cell_centre(index)
			if height > summary.highest_height:
				summary.highest_height = height
				highest_point = terrain.cell_centre(index)
			var type_id := terrain.type_id_of_cell(index)
			type_counts[type_id] = int(type_counts.get(type_id, 0)) + 1
	if summary.cells <= 0:
		return summary
	var divisor := float(summary.cells)
	summary.mean_slope /= divisor
	summary.mean_movement /= divisor
	summary.mean_cover /= divisor
	summary.mean_vegetation /= divisor
	summary.mean_wetness /= divisor
	summary.traversable_fraction = 1.0 - float(summary.blocked_cells) / divisor
	summary.uphill = (highest_point - lowest_point).normalized() if highest_point.distance_to(lowest_point) > 0.001 else Vector2.ZERO
	var best := 0
	for type_id in type_counts.keys():
		var count := int(type_counts[type_id])
		if count > best:
			best = count
			summary.dominant_type = str(type_id)
	return summary


## Grade the ground a body of men covers, which is what a formation actually asks about.
static func grade_formation(terrain: BattlefieldTerrain, formation: BattleFormation) -> TerrainSummary:
	if formation == null:
		return TerrainSummary.new()
	var bounds := formation.bounds()
	# A body is a line of men rather than a rectangle: a rank is a strip, and grading the rectangle
	# around it would report ground nobody is standing on. The strip is grown by a soldier's own
	# width so the men at the ends are included.
	return grade(terrain, bounds.grow(1.0))


## How a commander would describe this ground in one word.
func grade_name() -> String:
	if cells == 0:
		return "unknown"
	if traversable_fraction < 0.5:
		return "unusable"
	if mean_wetness >= 0.6:
		return "boggy"
	if mean_slope >= 0.45 or worst_slope >= 1.0:
		return "broken"
	if mean_vegetation >= 0.5:
		return "overgrown"
	if mean_slope >= 0.18:
		return "rolling"
	return "level"


## Uphill, downhill or neither, for a body facing a given way. This is the question an attack order
## wants answered, and it is a comparison rather than a query.
func slope_against(direction: Vector2) -> float:
	if direction.length_squared() <= 0.0001 or uphill.length_squared() <= 0.0001:
		return 0.0
	return uphill.normalized().dot(direction.normalized()) * mean_slope


func is_uphill(direction: Vector2) -> bool:
	return slope_against(direction) > 0.02


func is_downhill(direction: Vector2) -> bool:
	return slope_against(direction) < -0.02


func describe() -> String:
	if cells == 0:
		return "no ground"
	return "%s: %.0f%% passable, slope %.2f, x%.2f speed, cover %.2f%s" % [
		grade_name(), traversable_fraction * 100.0, mean_slope, mean_movement, mean_cover,
		" (uphill)" if is_uphill(uphill) else "",
	]


func to_dict() -> Dictionary:
	return {
		"cells": cells,
		"grade": grade_name(),
		"mean_slope": mean_slope,
		"worst_slope": worst_slope,
		"mean_movement": mean_movement,
		"traversable_fraction": traversable_fraction,
		"mean_cover": mean_cover,
		"mean_vegetation": mean_vegetation,
		"mean_wetness": mean_wetness,
		"blocked_cells": blocked_cells,
		"dominant_type": dominant_type,
	}
