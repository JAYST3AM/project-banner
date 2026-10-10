class_name BattleGpuRetentionProbe
extends RefCounted
## Read-only Vulkan shadow of the CPU's remembered-opponent eligibility rule.
## Output is four int32s per soldier; empty means HARD failure, no fallback.
const SHADER_PATH := "res://shaders/dev/gpu_combat_retention.glsl"
const LOCAL_SIZE := 64
var _rd: RenderingDevice = null
var _shader: RID
var _pipeline: RID
var _set: RID
var _roster: RID
var _geometry: RID
var _result: RID
var _capacity := 0
var last_error := ""


func open(capacity: int) -> bool:
	close()
	if capacity < 1:
		last_error = "retention capacity must be positive"
		return false
	_rd = RenderingServer.get_rendering_device()
	if _rd == null:
		last_error = "Vulkan device unavailable"
		return false
	var resource: RDShaderFile = load(SHADER_PATH) as RDShaderFile
	if resource == null:
		last_error = "retention shader unavailable or not imported"
		return false
	var spirv := resource.get_spirv()
	var failure := spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
	if not failure.is_empty():
		last_error = failure
		return false
	_shader = _rd.shader_create_from_spirv(spirv)
	if not _shader.is_valid():
		last_error = "retention shader allocation failed"
		close()
		return false
	_pipeline = _rd.compute_pipeline_create(_shader)
	if not _pipeline.is_valid():
		last_error = "retention pipeline allocation failed"
		close()
		return false
	_capacity = capacity
	var a := PackedByteArray()
	a.resize(capacity * 16)
	_roster = _rd.storage_buffer_create(a.size(), a)
	_geometry = _rd.storage_buffer_create(a.size(), a)
	_result = _rd.storage_buffer_create(a.size(), a)
	if not _roster.is_valid() or not _geometry.is_valid() or not _result.is_valid():
		last_error = "retention storage buffer allocation failed"
		close()
		return false
	var uniforms: Array[RDUniform] = []
	for entry in [[0, _roster], [1, _geometry], [2, _result]]:
		var u := RDUniform.new()
		u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		u.binding = int(entry[0])
		u.add_id(entry[1])
		uniforms.append(u)
	_set = _rd.uniform_set_create(uniforms, _shader, 0)
	if not _set.is_valid():
		last_error = "retention uniform set failed"
		close()
		return false
	last_error = ""
	return true


func evaluate(sim: BattleSimulator) -> PackedInt32Array:
	if sim == null or _rd == null or not _set.is_valid() or \
			sim.units.size() < 1 or sim.units.size() > _capacity:
		last_error = "retention GPU not initialized or wrong roster capacity"
		return PackedInt32Array()
	var ids := PackedInt32Array()
	var positions := PackedFloat32Array()
	for unit in sim.units:
		if unit == null:
			last_error = "null battle soldier"
			return PackedInt32Array()
		var search := unit.awareness_radius if unit.awareness_radius > 0.0 \
			else sim.target_search_radius
		var radius := maxf(search, sim.target_retention_radius)
		ids.append_array(PackedInt32Array([unit.id,
			0 if unit.side == BattleContext.SIDE_PLAYER else 1,
			1 if unit.is_alive() else 0, unit.auto_target_id]))
		positions.append_array(PackedFloat32Array([unit.position.x, unit.position.y,
			radius, unit.attack_range * sim.target_contact_loss_factor]))
	var encoded := ids.to_byte_array()
	var geometry := positions.to_byte_array()
	_rd.buffer_update(_roster, 0, encoded.size(), encoded)
	_rd.buffer_update(_geometry, 0, geometry.size(), geometry)
	var list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(list, _pipeline)
	_rd.compute_list_bind_uniform_set(list, _set, 0)
	_rd.compute_list_set_push_constant(list,
		PackedInt32Array([sim.units.size()]).to_byte_array(), 4)
	_rd.compute_list_dispatch(list,
		(sim.units.size() + LOCAL_SIZE - 1) / LOCAL_SIZE, 1, 1)
	_rd.compute_list_end()
	var ints := _rd.buffer_get_data(_result).to_int32_array()
	if ints.size() < sim.units.size() * 4:
		last_error = "short GPU retention readback"
		return PackedInt32Array()
	return ints.slice(0, sim.units.size() * 4)


func close() -> void:
	if _rd != null:
		if _set.is_valid():
			_rd.free_rid(_set)
		if _pipeline.is_valid():
			_rd.free_rid(_pipeline)
		if _shader.is_valid():
			_rd.free_rid(_shader)
		if _roster.is_valid():
			_rd.free_rid(_roster)
		if _geometry.is_valid():
			_rd.free_rid(_geometry)
		if _result.is_valid():
			_rd.free_rid(_result)
	_set = RID()
	_pipeline = RID()
	_shader = RID()
	_roster = RID()
	_geometry = RID()
	_result = RID()
	_rd = null
	_capacity = 0
