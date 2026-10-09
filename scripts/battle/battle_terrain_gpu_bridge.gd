class_name BattleTerrainGpuBridge
extends RefCounted
## E3 foundation: prepare exactly the live battle's authoritative terrain
## for GPU collision. This class does NOT run combat, create a RenderingDevice,
## or mutate deployment. The consumer may upload only a ready snapshot.
##
## Capture takes the already-generated and deployment-cleared BattlefieldTerrain
## owned by BattleSimulator. It never generates another terrain from a seed.
## The source identity and signature allow the uploader to refuse stale data.


static func capture(terrain: BattlefieldTerrain,
		units: Array[BattleUnit]) -> Dictionary:
	var report := {
		"ready": false,
		"reason": "",
		"source_id": 0,
		"source_signature": "",
		"mask": PackedInt32Array(),
		"bytes": PackedByteArray(),
		"units_checked": 0,
		"blocked_count": 0,
		"blocked_ids": PackedInt32Array(),
	}
	if terrain == null or not terrain.is_valid():
		report["reason"] = "no valid authoritative battlefield"
		return report

	var mask := BattleTerrainGpuMask.from_terrain(terrain)
	if mask.size() != BattleTerrainGpuMask.HEADER_INTS + terrain.cols * terrain.rows or \
			mask[0] != terrain.cols or mask[1] != terrain.rows or mask[3] != 1:
		report["reason"] = "authoritative terrain encoded as an invalid or disabled mask"
		return report

	report["source_id"] = terrain.get_instance_id()
	report["source_signature"] = terrain.signature()
	report["mask"] = mask
	report["bytes"] = mask.to_byte_array()
	var blocked := PackedInt32Array()
	var blocked_total := 0
	var checked := 0
	for unit in units:
		if unit == null or not unit.is_alive():
			continue
		checked += 1
		if BattleTerrainGpuMask.is_blocked(mask, unit.position):
			blocked_total += 1
			if blocked.size() < 12:
				blocked.append(unit.id)
	report["units_checked"] = checked
	report["blocked_count"] = blocked_total
	report["blocked_ids"] = blocked
	if blocked_total > 0:
		report["reason"] = "%d soldiers deployed on impassable terrain" % blocked_total
		return report
	report["ready"] = true
	return report


## Called immediately before upload: a terrain re-generation, terrain edit,
## or a different battlefield must invalidate any previously captured mask.
static func matches_source(report: Dictionary, terrain: BattlefieldTerrain) -> bool:
	if not bool(report.get("ready", false)) or terrain == null or not terrain.is_valid():
		return false
	return int(report.get("source_id", 0)) == terrain.get_instance_id() and \
			str(report.get("source_signature", "")) == terrain.signature()
