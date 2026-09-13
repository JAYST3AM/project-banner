class_name Party
extends RefCounted
## A group of soldiers travelling together.
##
## One class covers the player's party, bandit bands, caravans and (later) lord
## armies. A party owns [i]membership[/i] only - it stores soldier ids, not
## soldier objects - so the [CampaignState] registry stays the single source of
## truth and no soldier can exist in two places at once after a save/load.

const KIND_PLAYER := "player"
const KIND_BANDIT := "bandit"
const KIND_CARAVAN := "caravan"
const KIND_ARMY := "army"

var id: String = ""
var kind: String = KIND_BANDIT
var display_name: String = ""
var faction_id: String = ""
var leader_name: String = ""
var member_ids: Array[String] = []


func is_player() -> bool:
	return kind == KIND_PLAYER


## Historical roster membership: everyone who has ever belonged to this party,
## [b]including the dead[/b].
##
## This is deliberately [i]not[/i] a measure of strength. For the current fieldable
## force use [method CampaignState.active_member_count]. The two diverge as soon as
## anyone dies, and code that wants the force size but reads this will let a party
## of corpses march at full speed and appear to be at capacity when it is not.
func size() -> int:
	return member_ids.size()


func has_member(soldier_id: String) -> bool:
	return member_ids.has(soldier_id)


func add_member(soldier_id: String) -> bool:
	if soldier_id.is_empty() or member_ids.has(soldier_id):
		return false
	member_ids.append(soldier_id)
	return true


func remove_member(soldier_id: String) -> bool:
	var idx := member_ids.find(soldier_id)
	if idx < 0:
		return false
	member_ids.remove_at(idx)
	return true


func to_dict() -> Dictionary:
	return {
		"id": id,
		"kind": kind,
		"display_name": display_name,
		"faction_id": faction_id,
		"leader_name": leader_name,
		"member_ids": member_ids.duplicate(),
	}


static func from_dict(data: Dictionary) -> Party:
	var p := Party.new()
	p.id = str(data.get("id", ""))
	p.kind = str(data.get("kind", KIND_BANDIT))
	p.display_name = str(data.get("display_name", "Unnamed Party"))
	p.faction_id = str(data.get("faction_id", ""))
	p.leader_name = str(data.get("leader_name", ""))
	p.member_ids.clear()
	for m in data.get("member_ids", []):
		p.member_ids.append(str(m))
	return p
