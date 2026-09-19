extends Node
## Throwaway microphone benchmark: how much of the per-soldier sprite step is the CALL SHAPE?
##
## Four shapes, same maths, same writes:
##   A: the shipped shape - five static calls a soldier (plan, frame, origin, custom, write)
##   B: one fused static call a soldier, everything passed in
##   C: everything inlined in the loop, no calls at all
##   D: C plus "write only what changed" (origin when moved, frame when it changed)
## Run: godotc --headless --path <proj> res://scenes/dev/sprite_pack_bench.tscn

const N := 2000
const REPS := 60


func _ready() -> void:
	var buffer := PackedFloat32Array()
	buffer.resize(N * 16)
	var offsets := PackedInt32Array([0, 5, 3, 7, 8, 12])
	var ticks := PackedInt32Array([4, 3, 2, 3, 2])
	var frames := PackedInt32Array([6, 8, 6, 4, 4])
	var uv := PackedVector4Array()
	uv.resize(5 * 8)
	for i in uv.size():
		uv[i] = Vector4(0.01 * float(i % 6), 0.01 * float(i / 8), 0.05, 0.05)
	var common := PackedFloat32Array([38.0, 31.0, 15.5, 0.0, 0.16, 12.0, 12.0])
	var seen := PackedInt32Array()
	seen.resize(N)
	var written := PackedInt32Array()
	written.resize(N)
	written.fill(-1)
	var positions := PackedVector2Array()
	positions.resize(N)
	for i in N:
		positions[i] = Vector2(float(i % 100) * 1.3, float(i / 100) * 1.1)

	var t0 := Time.get_ticks_usec()
	for rep in REPS:
		for i in N:
			_shape_a(buffer, i, offsets, 16, ticks, frames, uv, common)
	var a := (Time.get_ticks_usec() - t0) / float(N * REPS)

	t0 = Time.get_ticks_usec()
	for rep in REPS:
		for i in N:
			_shape_b(buffer, i, offsets, ticks, frames, uv, 8, common, positions[i], true, false, false,
				(rep * 3 + i) % 40, i, false)
	var b := (Time.get_ticks_usec() - t0) / float(N * REPS)

	t0 = Time.get_ticks_usec()
	for rep in REPS:
		for i in N:
			_shape_c_inline(buffer, offsets, ticks, frames, uv, 8, common, positions[i], (rep * 3 + i) % 40, i)
	var c := (Time.get_ticks_usec() - t0) / float(N * REPS)

	t0 = Time.get_ticks_usec()
	for rep in REPS:
		for i in N:
			_shape_d_dirty(buffer, offsets, ticks, frames, uv, 8, common, positions[i], (rep * 3 + i) % 40, i, written, rep % 4 == 0)
	var d := (Time.get_ticks_usec() - t0) / float(N * REPS)

	print("sprite pack bench (%d soldiers x %d reps)" % [N, REPS])
	print("  A five static calls : %.3f us a soldier" % a)
	print("  B one fused call    : %.3f us a soldier" % b)
	print("  C all inline        : %.3f us a soldier" % c)
	print("  D inline + dirty    : %.3f us a soldier" % d)
	print("  -> A/B ratio %.2f, A/C ratio %.2f, A/D ratio %.2f" % [a / b, a / c, a / d])
	get_tree().quit()


## ---------- shape A: the shipped call graph (simplified to the same writes) ----------

func _shape_a(buffer: PackedFloat32Array, i: int, offsets: PackedInt32Array, stride: int,
		ticks: PackedInt32Array, frames: PackedInt32Array, uv: PackedVector4Array,
		common: PackedFloat32Array) -> void:
	var anim := _plan(true, false, 40, 40, int(common[5]), int(common[6]))
	var into := i * 7
	var frame := _frame(anim, into, ticks[anim], frames[anim])
	var cell := Vector2(common[0], common[1])
	var origin := _origin(Vector2(float(i % 100) * 1.3, float(i / 100) * 1.1), cell, Vector2(common[2], common[3]), common[4])
	var custom := _custom(uv[anim * 8 + frame], false)
	_write(buffer, i, stride, offsets, origin, cell * common[4], custom)


func _plan(alive: bool, moved: bool, hurt_age: int, strike_age: int, hurt_window: int, attack_window: int) -> int:
	if not alive:
		return 4
	if hurt_age >= 0 and hurt_age < hurt_window:
		return 3
	if strike_age >= 0 and strike_age < attack_window:
		return 2
	if moved:
		return 1
	return 0


func _frame(animation: int, ticks_into: int, ticks_per_frame_count: int, count: int) -> int:
	var per := maxi(1, ticks_per_frame_count)
	var frames_count := maxi(1, count)
	var index := int(ticks_into / per)
	if animation == 4:
		return clampi(index, 0, frames_count - 1)
	return posmod(index, frames_count)


func _origin(foot: Vector2, cell: Vector2, anchor: Vector2, units_per_pixel: float) -> Vector2:
	return Vector2(
		foot.x + cell.x * units_per_pixel * 0.5 - anchor.x * units_per_pixel,
		foot.y - cell.y * units_per_pixel * 0.5)


func _custom(uv: Vector4, flip: bool) -> Vector4:
	if flip:
		return Vector4(uv.x + uv.z, uv.y, -uv.z, uv.w)
	return uv


func _write(buffer: PackedFloat32Array, i: int, stride: int, offsets: PackedInt32Array,
		origin: Vector2, size: Vector2, custom: Vector4) -> void:
	var base := i * stride
	buffer[base + offsets[0]] = size.x
	buffer[base + offsets[1]] = size.y
	buffer[base + offsets[2]] = origin.x
	buffer[base + offsets[3]] = origin.y
	buffer[base + offsets[5]] = custom.x
	buffer[base + offsets[5] + 1] = custom.y
	buffer[base + offsets[5] + 2] = custom.z
	buffer[base + offsets[5] + 3] = custom.w


## ---------- shape B: one fused call ----------

func _shape_b(buffer: PackedFloat32Array, i: int, offsets: PackedInt32Array, ticks: PackedInt32Array,
		frames: PackedInt32Array, uv: PackedVector4Array, stride: int, common: PackedFloat32Array,
		position: Vector2, alive: bool, moved: bool, flip: bool, into: int, phase: int,
		desync: bool) -> void:
	var anim := 0
	if not alive:
		anim = 4
	elif into < 12:
		anim = 3
	elif into < 12:
		anim = 2
	elif moved:
		anim = 1
	var frame := posmod(int((into + phase * 7) / maxi(1, ticks[anim])), maxi(1, frames[anim]))
	var cell := Vector2(common[0], common[1])
	var scale := common[4]
	var foot := position + Vector2(0.0, 0.85)
	var origin := Vector2(foot.x + cell.x * scale * 0.5 - common[2] * scale, foot.y - cell.y * scale * 0.5)
	var rect := uv[anim * 8 + frame]
	var base := i * stride
	buffer[base + offsets[0]] = cell.x * scale
	buffer[base + offsets[1]] = cell.y * scale
	buffer[base + offsets[2]] = origin.x
	buffer[base + offsets[3]] = origin.y
	if flip:
		buffer[base + offsets[5]] = rect.x + rect.z
		buffer[base + offsets[5] + 2] = -rect.z
	else:
		buffer[base + offsets[5]] = rect.x
		buffer[base + offsets[5] + 2] = rect.z
	buffer[base + offsets[5] + 1] = rect.y
	buffer[base + offsets[5] + 3] = rect.w


## ---------- shape C: inline, no calls ----------

func _shape_c_inline(buffer: PackedFloat32Array, offsets: PackedInt32Array, ticks: PackedInt32Array,
		frames: PackedInt32Array, uv: PackedVector4Array, stride: int, common: PackedFloat32Array,
		position: Vector2, into: int, phase: int) -> void:
	var anim := 0
	if into < 12:
		anim = 3
	var per := maxi(1, ticks[anim])
	var frame := posmod(int((into + phase * 7) / per), maxi(1, frames[anim]))
	var cell_w := common[0]
	var cell_h := common[1]
	var scale := common[4]
	var foot_x := position.x
	var foot_y := position.y + 0.85
	var origin_x := foot_x + cell_w * scale * 0.5 - common[2] * scale
	var origin_y := foot_y - cell_h * scale * 0.5
	var rect := uv[anim * 8 + frame]
	var base := phase * stride
	buffer[base + offsets[0]] = cell_w * scale
	buffer[base + offsets[1]] = cell_h * scale
	buffer[base + offsets[2]] = origin_x
	buffer[base + offsets[3]] = origin_y
	buffer[base + offsets[5]] = rect.x
	buffer[base + offsets[5] + 1] = rect.y
	buffer[base + offsets[5] + 2] = rect.z
	buffer[base + offsets[5] + 3] = rect.w


## ---------- shape D: inline + only what changed ----------

func _shape_d_dirty(buffer: PackedFloat32Array, offsets: PackedInt32Array, ticks: PackedInt32Array,
		frames: PackedInt32Array, uv: PackedVector4Array, stride: int, common: PackedFloat32Array,
		position: Vector2, into: int, phase: int, written: PackedInt32Array, moved: bool) -> void:
	var anim := 0
	if into < 12:
		anim = 3
	var frame := posmod(int((into + phase * 7) / maxi(1, ticks[anim])), maxi(1, frames[anim]))
	var key := anim * 8 + frame
	var base := phase * stride
	if written[phase] != key:
		written[phase] = key
		var rect := uv[key]
		buffer[base + offsets[5]] = rect.x
		buffer[base + offsets[5] + 1] = rect.y
		buffer[base + offsets[5] + 2] = rect.z
		buffer[base + offsets[5] + 3] = rect.w
	if moved:
		var scale := common[4]
		buffer[base + offsets[2]] = position.x + common[0] * scale * 0.5 - common[2] * scale
		buffer[base + offsets[3]] = position.y + 0.85 - common[1] * scale * 0.5
