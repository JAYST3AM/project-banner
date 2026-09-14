extends Node

## Benchmark 0 - the price of crossing the GDScript -> native boundary.
##
## Step 7.7's question is whether moving the target-search kernel native is worth owning
## native code, and the first thing that decides it is not the kernel but the bridge: a fast
## inner loop behind an expensive boundary is not a win. This scene prices the boundary in
## isolation - a bare call, integer arguments, a Vector2, reading a packed array, asking for
## the candidate buffer - and then times the real composite: one `collect` on a
## twenty-thousand-soldier field at the densities the battle actually uses.
##
##   godot --headless --path . res://scenes/dev/bridge_bench.tscn
##   godot --headless --path . res://scenes/dev/bridge_bench.tscn -- --units=20000 --passes=3

const SIDE_PLAYER := "player"
const SIDE_ENEMY := "enemy"

var units: int = 20000
var passes: int = 3
var field: Vector2 = Vector2(633.0, 380.0)
var cell_size: float = 4.0
var radius: float = 32.0

var query: Object = null
var cells: PackedInt32Array = PackedInt32Array()
var bits: PackedInt32Array = PackedInt32Array()
var points: Array[Vector2] = []


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--units="):
			units = int(arg.substr(8))
		elif arg.begins_with("--passes="):
			passes = int(arg.substr(9))
		elif arg.begins_with("--radius="):
			radius = float(arg.substr(9))

	print("=== NATIVE BRIDGE COST (Benchmark 0) ===")
	if not ClassDB.class_exists("NativeTargetQuery"):
		print("  NativeTargetQuery is NOT loaded - build it with `bash native/build.sh`.")
		print("  (the GDScript reference path needs nothing: this scene only prices the bridge)")
		get_tree().quit(1)
		return

	query = ClassDB.instantiate("NativeTargetQuery")
	_build_field()
	print("  native class loaded: %s" % [query.get_class()])
	print("  field %.0fx%.0f, cell %.1f, %d units, radius %.1f, %d passes" % [
		field.x, field.y, cell_size, units, radius, passes])
	print("  (per-call = median of the passes; total/tick = per-call x the 2,438 looks a")
	print("   realistic 20K tick actually makes)")

	_price_call("ping()", func() -> void: query.bench_ping())
	_price_call("add(1,2)", func() -> void: query.bench_add(1, 2))
	_price_call("echo(Vector2)", func() -> void: query.bench_echo(Vector2(3.5, 7.25)))
	_price_call("fill(170)", func() -> void: query.bench_fill(170))
	_price_call("candidates() [read 170]", func() -> void:
		var buf: PackedInt32Array = query.candidates()
		if buf.size() > 0:
			var _peek := buf[0])
	_price_call("sum(PackedInt32Array[170])", func() -> void: query.bench_sum(_sample_ints))
	_price_call("collect(32) on the field", func() -> void: query.collect(points[0].x, points[0].y, radius, 2))
	_price_call("collect + read the candidates", func() -> void:
		var n: int = query.collect(points[0].x, points[0].y, radius, 2)
		var buf: PackedInt32Array = query.candidates()
		var acc := 0
		for i in n:
			acc += buf[i])

	_report_shape()
	print("=== BRIDGE BENCHMARK COMPLETE ===")
	get_tree().quit(0)


## A standalone integer buffer the size of one search's candidate list, for the read probe.
var _sample_ints: PackedInt32Array = PackedInt32Array()


func _build_field() -> void:
	var cols := int(field.x / cell_size) + 1
	var rows := int(field.y / cell_size) + 1
	query.call("setup", cols, rows, cell_size, 1.2, units)
	cells.resize(units)
	bits.resize(units)
	_sample_ints.resize(170)
	# Two ranks facing each other across a narrow gap, the way the battle's approach looks,
	# and the query points are taken *inside* the crowds rather than in the empty ground
	# between them. An earlier version of this scene placed the bodies far apart and sampled
	# the gap: every collect then found nobody, walked no cells, and priced a call at half a
	# microsecond for work it had not done. The numbers below are the ones that matter, so
	# the field has to be one where the kernel actually works.
	for i in units:
		var on_left := (i % 2) == 0
		var rank := i / 2
		var x := field.x * 0.5 + (-1.0 if on_left else 1.0) * (12.0 + float(rank % 40) * 0.9)
		var y := 20.0 + float((rank / 40) % 340) * 1.0
		var col := int(floor(x / cell_size))
		var row := int(floor(y / cell_size))
		cells[i] = row * cols + col
		bits[i] = 1 if on_left else 2
		_sample_ints[i % 170] = i
	for i in 128:
		var t := float(i) / 128.0
		# Along the seam, where a search has friends on one side and enemies on the other.
		var side := -1.0 if (i % 2) == 0 else 1.0
		points.append(Vector2(field.x * 0.5 + side * (2.0 + t * 14.0), 180.0 + (t - 0.5) * 300.0))
	query.call("rebuild", cells, bits)


func _price_call(label: String, fn: Callable) -> void:
	# Warm up first: the first native call in a process pays for lazily-bound internals that
	# a battle would pay for once, not per search.
	for i in 32:
		fn.call()
	var samples: Array[float] = []
	for pass_i in passes:
		var started := Time.get_ticks_usec()
		for i in 20000:
			fn.call()
		samples.append(float(Time.get_ticks_usec() - started) / 20000.0)
	samples.sort()
	var per_call := samples[samples.size() / 2]
	print("  %-30s %9.4f us/call   %10.2f ms per 20K-call tick" % [label, per_call, per_call * 2438.0 / 1000.0])


func _report_shape() -> void:
	# What one native collect actually hands back, so the numbers above can be read against
	# the work: the transfer is not free and is not small.
	var totals := 0
	var max_n := 0
	query.call("rebuild", cells, bits)
	for point in points:
		var n: int = query.collect(point.x, point.y, radius, 2)
		totals += n
		max_n = maxi(max_n, n)
	print("  candidates handed back: %.1f per collect, worst %d, across %d sampled points" % [
		float(totals) / maxf(1.0, float(points.size())), max_n, points.size()])
	print("  cells read by the last collect: %d (occupied walk: %s)" % [
		query.call("last_cells_read"), "yes" if query.call("last_walked_occupied") == 1 else "no"])
