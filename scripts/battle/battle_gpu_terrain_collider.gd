class_name BattleGpuTerrainCollider
extends RefCounted
## Opt-in live-battle terrain collision on the real rendering device.
## CPU BattleSimulator still owns movement intentions, combat and campaign
## resolution. E2's proven shader mode 6 resolves ALL live proposed positions
## against the exact BattleSimulator terrain mask in one GPU dispatch per tick.
## This is NOT full GPU soldier/combat simulation.
const SHADER_PATH := "res://shaders/dev/crowd_sim.glsl"
const LOCAL_SIZE := 256
const BINDINGS := 15
var _rd: RenderingDevice = null
var _shader: RID
var _pipeline: RID
var _uniform_set: RID
var _buffers: Array[RID] = []
var _capacity := 0
var _source_id := 0
var _source_signature := ""
var last_error := ""


func open(report: Dictionary, terrain: BattlefieldTerrain, capacity: int) -> bool:
	close()
	if capacity < 1 or not BattleTerrainGpuBridge.matches_source(report, terrain):
		last_error = "terrain source mismatch or empty unit roster"
		return false
	_rd = RenderingServer.get_rendering_device()
	if _rd == null:
		last_error = "Vulkan rendering device unavailable"
		return false
	var shader_file: RDShaderFile = load(SHADER_PATH) as RDShaderFile
	if shader_file == null:
		last_error = "E2 compute shader unavailable"
		return false
	var spirv := shader_file.get_spirv()
	var error := spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
	if not error.is_empty():
		last_error = error
		return false
	_shader = _rd.shader_create_from_spirv(spirv)
	if not _shader.is_valid():
		last_error = "shader_create_from_spirv failed"
		close()
		return false
	_pipeline = _rd.compute_pipeline_create(_shader)
	if not _pipeline.is_valid():
		last_error = "compute_pipeline_create failed"
		close()
		return false
	_capacity = capacity
	var payload: PackedByteArray = report["bytes"]
	if payload.size() < 20:
		last_error = "enabled terrain mask truncated"
		close()
		return false
	_buffers.clear()
	for binding in BINDINGS:
		var bytes := PackedByteArray()
		if binding == 0 or binding == 1:
			bytes.resize(_capacity * 16)
		elif binding == 14:
			bytes = payload
		else:
			bytes.resize(16)
		var buffer := _rd.storage_buffer_create(bytes.size(), bytes)
		if not buffer.is_valid():
			last_error = "storage buffer %d allocation failed" % binding
			close()
			return false
		_buffers.append(buffer)
	var uniforms: Array[RDUniform] = []
	for binding in BINDINGS:
		var uniform := RDUniform.new()
		uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		uniform.binding = binding
		uniform.add_id(_buffers[binding])
		uniforms.append(uniform)
	_uniform_set = _rd.uniform_set_create(uniforms, _shader, 0)
	if not _uniform_set.is_valid() or _rd.buffer_get_data(_buffers[14]) != payload:
		last_error = "binding 14 readback or uniform set failed"
		close()
		return false
	_source_id = terrain.get_instance_id()
	_source_signature = str(report["source_signature"])
	last_error = ""
	return true


func matches_terrain(terrain: BattlefieldTerrain) -> bool:
	return terrain != null and terrain.is_valid() and \
		_source_id == terrain.get_instance_id() and \
		_source_signature == terrain.signature()


## Returns an empty array on failure, never silently falls back to CPU.
## before/after each contain one entry per BattleSimulator unit, including dead.
func resolve(before: PackedVector2Array, after: PackedVector2Array) -> PackedVector2Array:
	if _rd == null or not _uniform_set.is_valid() or before.size() != after.size() or \
			before.size() > _capacity or before.is_empty():
		last_error = "GPU collider not initialized or invalid batch size"
		return PackedVector2Array()
	var inputs := PackedFloat32Array()
	var proposals := PackedFloat32Array()
	for i in before.size():
		inputs.append_array(PackedFloat32Array([before[i].x, before[i].y, 0.0, 0.0]))
		proposals.append_array(PackedFloat32Array([after[i].x, after[i].y, 0.0, 0.0]))
	var source := inputs.to_byte_array()
	var target := proposals.to_byte_array()
	_rd.buffer_update(_buffers[0], 0, source.size(), source)
	_rd.buffer_update(_buffers[1], 0, target.size(), target)
	var commands := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(commands, _pipeline)
	_rd.compute_list_bind_uniform_set(commands, _uniform_set, 0)
	_rd.compute_list_set_push_constant(commands,
		PackedInt32Array([6, before.size(), 0, 0]).to_byte_array(), 16)
	_rd.compute_list_dispatch(commands, (before.size() + LOCAL_SIZE - 1) / LOCAL_SIZE, 1, 1)
	_rd.compute_list_end()
	var floats := _rd.buffer_get_data(_buffers[0]).to_float32_array()
	if floats.size() < before.size() * 4:
		last_error = "short GPU position readback"
		return PackedVector2Array()
	var output := PackedVector2Array()
	for i in before.size():
		var point := Vector2(floats[i * 4], floats[i * 4 + 1])
		if not point.is_finite():
			last_error = "nonfinite GPU collision result at %d" % i
			return PackedVector2Array()
		output.append(point)
	return output


func close() -> void:
	if _rd != null:
		if _uniform_set.is_valid():
			_rd.free_rid(_uniform_set)
		if _pipeline.is_valid():
			_rd.free_rid(_pipeline)
		if _shader.is_valid():
			_rd.free_rid(_shader)
		for buffer in _buffers:
			if buffer.is_valid():
				_rd.free_rid(buffer)
	_buffers.clear()
	_uniform_set = RID()
	_pipeline = RID()
	_shader = RID()
	_rd = null
	_capacity = 0
	_source_id = 0
	_source_signature = ""
