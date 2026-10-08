class_name BattlePlacementPlanner
extends RefCounted
## Pure, deterministic positioning for multi-formation commands.
## No scene, GPU, animation or campaign state enters this planner.
## One shared shift keeps selected bodies separate at field edges; impossible
## layouts return an empty plan instead of flattening bodies onto one point.


static func _on_field(point: Vector2, field: Vector2) -> Vector2:
	return Vector2(
		clampf(point.x, 4.0, maxf(4.0, field.x - 4.0)),
		clampf(point.y, 4.0, maxf(4.0, field.y - 4.0)))


## Keep each formation centre inside the field by moving the WHOLE group.
## Clamping centres individually destroys relative offsets at world boundaries.
## If the original spread cannot fit inside the margins, reject the plan.
static func _fit_group(plan: Array[Dictionary], field: Vector2) -> Array[Dictionary]:
	if plan.is_empty():
		return plan
	var minimum := Vector2(4.0, 4.0)
	var maximum := Vector2(maxf(minimum.x, field.x - 4.0),
		maxf(minimum.y, field.y - 4.0))
	var smallest := Vector2(INF, INF)
	var largest := Vector2(-INF, -INF)
	for placement in plan:
		var anchor: Vector2 = placement.get("anchor", Vector2.ZERO)
		if not anchor.is_finite():
			return []
		smallest = smallest.min(anchor)
		largest = largest.max(anchor)
	if largest.x - smallest.x > maximum.x - minimum.x + 0.001 \
			or largest.y - smallest.y > maximum.y - minimum.y + 0.001:
		return []
	var shift := Vector2.ZERO
	if smallest.x < minimum.x:
		shift.x = minimum.x - smallest.x
	elif largest.x > maximum.x:
		shift.x = maximum.x - largest.x
	if smallest.y < minimum.y:
		shift.y = minimum.y - smallest.y
	elif largest.y > maximum.y:
		shift.y = maximum.y - largest.y
	for placement in plan:
		var anchor: Vector2 = placement["anchor"]
		placement["anchor"] = anchor + shift
	return plan


## A normal right click moves the group without collapsing its separate bodies.
## The click is the requested centre, not the target for every formation.
static func translated(bodies: Array[Dictionary], destination: Vector2, field: Vector2) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if bodies.is_empty():
		return result
	var centre := Vector2.ZERO
	for body in bodies:
		var anchor: Vector2 = body.get("anchor", Vector2.ZERO)
		centre += anchor
	centre /= float(bodies.size())
	for body in bodies:
		var anchor: Vector2 = body.get("anchor", Vector2.ZERO)
		result.append({
			"id": int(body.get("id", -1)),
			"anchor": destination + anchor - centre,
			"forward": body.get("forward", Vector2.RIGHT),
			"files": int(body.get("files", 1)),
		})
	return _fit_group(result, field)


## A Total War-style right-drag: line between start/end is the new frontage.
## Each selected formation remains a separate body, laid side by side in the
## relative order it occupied on that axis before the drag.
static func frontage(bodies: Array[Dictionary], from: Vector2, to: Vector2,
		field: Vector2) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if bodies.is_empty():
		return result
	var start := _on_field(from, field)
	var stop := _on_field(to, field)
	var delta := stop - start
	var length := delta.length()
	if length < 0.001:
		return translated(bodies, start, field)
	var across := delta / length
	var forward := Vector2(across.y, -across.x)
	var original_forward := Vector2.ZERO
	var ordered: Array[Dictionary] = bodies.duplicate()
	for body in bodies:
		var facing: Vector2 = body.get("forward", Vector2.RIGHT)
		original_forward += facing.normalized() if facing.length_squared() > 0.0001 else Vector2.RIGHT
	if original_forward.dot(forward) < 0.0:
		forward = -forward
	ordered.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var first: Vector2 = a.get("anchor", Vector2.ZERO)
		var second: Vector2 = b.get("anchor", Vector2.ZERO)
		return first.dot(across) < second.dot(across))
	var troops := 0
	for body in ordered:
		troops += maxi(1, int(body.get("members", 1)))
	var gap := 2.0 if ordered.size() > 1 else 0.0
	var allotted := maxf(length - float(ordered.size() - 1) * gap, float(ordered.size()) * 3.0)
	var cursor := 0.0
	for body in ordered:
		var members := maxi(1, int(body.get("members", 1)))
		var spacing := maxf(0.5, float(body.get("spacing", 2.0)))
		var segment := allotted * float(members) / float(maxi(1, troops))
		var desired_files := maxi(1, int(round(segment / spacing)))
		var max_ranks := maxi(1, int(floor(maxf(8.0, field.x - 16.0) / spacing)))
		var min_files := maxi(1, int(ceil(float(members) / float(max_ranks))))
		var files := clampi(desired_files, min_files, members)
		var new_centre := start + across * (cursor + segment * 0.5)
		result.append({
			"id": int(body.get("id", -1)),
			"anchor": new_centre,
			"forward": forward,
			"files": files,
		})
		cursor += segment + gap
	return _fit_group(result, field)
