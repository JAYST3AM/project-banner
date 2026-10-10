class_name BattleGpuOrderedTargetProbe
extends RefCounted
## GPU combat slice 1: shadow-only explicit-order target validation.
## No combat state is written to the GPU and no GPU result drives the battle.
const SHADER_PATH := "res://shaders/dev/gpu_combat_equivalence.glsl"
const WORKGROUP := 64
var _rd: RenderingDevice = null
var _shader: RID
var _pipeline: RID
var _set: RID
var _input: RID
var _output: RID
var _capacity := 0
var last_error := ""


func open(max_soldiers: int) -> bool:
	close()
	if max_soldiers <= 0:
		last_error = "capacity must be positive"
		return false
	_rd = RenderingServer.get_rendering_device()
	if _rd == null:
		last_error = "windowed Vulkan rendering device is required"
		return false
	var resource: RDShaderFile = load(SHADER_PATH) as RDShaderFile
	if resource == null:
		last_error = "GPU combat shader was not imported"
		return false
	var spirv := resource.get_spirv()
	var error := spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
	if not error.is_empty():
		last_error = error
		return false
	_shader = _rd.shader_create_from_spirv(spirv)
	if not _shader.is_valid():
		last_error = "failed to create GPU combat shader"
		close()
		return false
	_pipeline = _rd.compute_pipeline_create(_shader)
	if not _pipeline.is_valid():
		last_error = "failed to create GPU combat pipeline"
		close()
		return false
	_capacity = max_soldiers
	var input_bytes := PackedByteArray()
	input_bytes.resize(_capacity * 16)
	var output_bytes := PackedByteArray()
	output_bytes.resize(_capacity * 4)
	_input = _rd.storage_buffer_create(input_bytes.size(), input_bytes)
	_output = _rd.storage_buffer_create(output_bytes.size(), output_bytes)
	if not _input.is_valid() or not _output.is_valid():
		last_error = "GPU combat buffer allocation failed"
		close()
		return false
	var uniforms: Array[RDUniform] = []
	for pair in [[0, _input], [1, _output]]:
		var uniform := RDUniform.new()
		uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		uniform.binding = int(pair[0])
		uniform.add_id(pair[1])
		uniforms.append(uniform)
	_set = _rd.uniform_set_create(uniforms, _shader, 0)
	if not _set.is_valid():
		last_error = "GPU combat uniform set failed"
		close()
		return false
	last_error = ""
	return true


## Each output is a candidate explicit-order target ID or -1.
## An empty array signals a HARD failure, never a CPU substitute.
func evaluate(roster: Array[BattleUnit]) -> PackedInt32Array:
	if _rd == null or not _set.is_valid() or roster.is_empty() or \
			roster.size() > _capacity:
		last_error = "GPU combat probe is closed or roster exceeds capacity"
		return PackedInt32Array()
	var packed := PackedInt32Array()
	for unit in roster:
		if unit == null:
			last_error = "GPU combat roster has a null soldier"
			return PackedInt32Array()
		packed.append(unit.id)
		packed.append(0 if unit.side == BattleContext.SIDE_PLAYER else 1)
		packed.append(1 if unit.is_alive() else 0)
		packed.append(unit.attack_order_target_id)
	var bytes := packed.to_byte_array()
	_rd.buffer_update(_input, 0, bytes.size(), bytes)
	var commands := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(commands, _pipeline)
	_rd.compute_list_bind_uniform_set(commands, _set, 0)
	_rd.compute_list_set_push_constant(commands,
		PackedInt32Array([roster.size()]).to_byte_array(), 4)
	_rd.compute_list_dispatch(commands, (roster.size() + WORKGROUP - 1) / WORKGROUP, 1, 1)
	_rd.compute_list_end()
	var returned := _rd.buffer_get_data(_output).to_int32_array()
	if returned.size() < roster.size():
		last_error = "short GPU explicit-target readback"
		return PackedInt32Array()
	return returned.slice(0, roster.size())


func close() -> void:
	if _rd != null:
		if _set.is_valid():
			_rd.free_rid(_set)
		if _pipeline.is_valid():
			_rd.free_rid(_pipeline)
		if _shader.is_valid():
			_rd.free_rid(_shader)
		if _input.is_valid():
			_rd.free_rid(_input)
		if _output.is_valid():
			_rd.free_rid(_output)
	_set = RID()
	_pipeline = RID()
	_shader = RID()
	_input = RID()
	_output = RID()
	_rd = null
	_capacity = 0
