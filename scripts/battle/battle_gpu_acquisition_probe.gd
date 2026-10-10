class_name BattleGpuAcquisitionProbe
extends RefCounted
## GPU S3: shadow-only nearest enemy search plus squared hysteresis.
## This class never writes BattleSimulator or BattleUnit state.
const SHADER_PATH := "res://shaders/dev/gpu_combat_acquisition.glsl"
const LOCAL_SIZE := 64
var _rd: RenderingDevice = null
var _shader: RID
var _pipeline: RID
var _set: RID
var _roster: RID
var _geometry: RID
var _orders: RID
var _result: RID
var _capacity: int = 0
var last_error := ""


func open(capacity: int) -> bool:
	close()
	if capacity <= 0:
		last_error = "GPU acquisition capacity must be positive"
		return false
	_rd = RenderingServer.get_rendering_device()
	if _rd == null:
		last_error = "windowed Vulkan device unavailable"
		return false
	var file: RDShaderFile = load(SHADER_PATH) as RDShaderFile
	if file == null:
		last_error = "acquisition shader not imported"
		return false
	var spirv := file.get_spirv()
	var compile_error := spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
	if not compile_error.is_empty():
		last_error = compile_error
		return false
	_shader = _rd.shader_create_from_spirv(spirv)
	if not _shader.is_valid():
		last_error = "acquisition shader allocation failed"
		close()
		return false
	_pipeline = _rd.compute_pipeline_create(_shader)
	if not _pipeline.is_valid():
		last_error = "acquisition pipeline allocation failed"
		close()
		return false
	_capacity = capacity
	var empty_bytes := PackedByteArray()
	empty_bytes.resize(capacity * 16)
	_roster = _rd.storage_buffer_create(empty_bytes.size(), empty_bytes)
	_geometry = _rd.storage_buffer_create(empty_bytes.size(), empty_bytes)
	_orders = _rd.storage_buffer_create(empty_bytes.size(), empty_bytes)
	_result = _rd.storage_buffer_create(empty_bytes.size(), empty_bytes)
	if not _roster.is_valid() or not _geometry.is_valid() or \
			not _orders.is_valid() or not _result.is_valid():
		last_error = "acquisition buffer allocation failed"
		close()
		return false
	var uniforms: Array[RDUniform] = []
	for entry in [[0, _roster], [1, _geometry], [2, _orders], [3, _result]]:
		var u := RDUniform.new()
		u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		u.binding = int(entry[0])
		u.add_id(entry[1])
		uniforms.append(u)
	_set = _rd.uniform_set_create(uniforms, _shader, 0)
	if not _set.is_valid():
		last_error = "acquisition uniform set allocation failed"
		close()
		return false
	last_error = ""
	return true


## Returns per-soldier ivec4: chosen, reason, local nearest, retained.
## Empty readback is always a gate failure, not permission to use CPU output.
func evaluate(sim: BattleSimulator) -> PackedInt32Array:
	if sim == null or _rd == null or not _set.is_valid() or \
			sim.units.is_empty() or sim.units.size() > _capacity:
		last_error = "GPU acquisition probe closed or roster outside capacity"
		return PackedInt32Array()
	var roster := PackedInt32Array()
	var geometry := PackedFloat32Array()
	var orders := PackedInt32Array()
	for unit in sim.units:
		if unit == null or (unit.side != BattleContext.SIDE_PLAYER and \
				unit.side != BattleContext.SIDE_ENEMY):
			last_error = "invalid soldier or side in acquisition roster"
			return PackedInt32Array()
		var awareness := unit.awareness_radius if unit.awareness_radius > 0.0 \
			else sim.target_search_radius
		var ceiling := maxf(awareness, sim.target_search_max_radius)
		var retention := maxf(awareness, sim.target_retention_radius)
		roster.append_array(PackedInt32Array([
			unit.id, 0 if unit.side == BattleContext.SIDE_PLAYER else 1,
			1 if unit.is_alive() else 0, unit.auto_target_id]))
		geometry.append_array(PackedFloat32Array([
			unit.position.x, unit.position.y, ceiling, retention]))
		orders.append_array(PackedInt32Array([unit.attack_order_target_id, 0, 0, 0]))
	var data := roster.to_byte_array()
	var positions := geometry.to_byte_array()
	var commands := orders.to_byte_array()
	_rd.buffer_update(_roster, 0, data.size(), data)
	_rd.buffer_update(_geometry, 0, positions.size(), positions)
	_rd.buffer_update(_orders, 0, commands.size(), commands)
	var parameters := PackedInt32Array([sim.units.size()]).to_byte_array()
	parameters.append_array(PackedFloat32Array([
		sim.target_switch_advantage * sim.target_switch_advantage]).to_byte_array())
	parameters.append_array(PackedInt32Array([0, 0]).to_byte_array())
	var list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(list, _pipeline)
	_rd.compute_list_bind_uniform_set(list, _set, 0)
	_rd.compute_list_set_push_constant(list, parameters, 16)
	_rd.compute_list_dispatch(list,
		(sim.units.size() + LOCAL_SIZE - 1) / LOCAL_SIZE, 1, 1)
	_rd.compute_list_end()
	var output := _rd.buffer_get_data(_result).to_int32_array()
	if output.size() < sim.units.size() * 4:
		last_error = "short GPU acquisition readback"
		return PackedInt32Array()
	last_error = ""
	return output.slice(0, sim.units.size() * 4)


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
		if _orders.is_valid():
			_rd.free_rid(_orders)
		if _result.is_valid():
			_rd.free_rid(_result)
	_set = RID()
	_pipeline = RID()
	_shader = RID()
	_roster = RID()
	_geometry = RID()
	_orders = RID()
	_result = RID()
	_rd = null
	_capacity = 0
