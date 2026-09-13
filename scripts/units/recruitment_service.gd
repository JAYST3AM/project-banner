class_name RecruitmentService
extends RefCounted
## The recruitment transaction.
##
## [method recruit] is the only way a soldier enters the player's party, and it
## performs the whole sequence in one place: check availability, check gold,
## deduct the cost, create the soldier, register it, add it to the party, and
## decrement the settlement's pool. Either all of that happens or none of it does.
##
## Every rejection carries a plain-English reason so the UI never has to guess
## why a button is disabled.

enum Code {
	OK,
	UNKNOWN_UNIT,
	NOT_AT_SETTLEMENT,
	PARTY_FULL,
	POOL_EMPTY,
	NOT_ENOUGH_GOLD,
	BAD_REQUEST,
}

var state: CampaignState = null
var config: GameConfig = null
var units: UnitCatalog = null
var factory: SoldierFactory = null


static func build(p_state: CampaignState, p_config: GameConfig) -> RecruitmentService:
	if p_state == null or p_config == null:
		return null
	var service := RecruitmentService.new()
	service.state = p_state
	service.config = p_config
	service.units = UnitCatalog.load_from()
	service.factory = SoldierFactory.build(p_state, p_config)
	return service


## ---------- queries ------------------------------------------------------

func max_party_size() -> int:
	return config.get_int("campaign.max_party_size", 24)


func party_capacity_remaining() -> int:
	# Only the living count against the cap: a party of corpses should never
	# block recruiting.
	return maxi(0, max_party_size() - state.active_members(state.player_party).size())


func available_at(settlement: Settlement, unit_type_id: String) -> int:
	if settlement == null:
		return 0
	return maxi(0, int(settlement.recruit_pool.get(unit_type_id, 0)))


func cost_for(unit_type_id: String) -> int:
	return units.recruit_cost(unit_type_id)


## Can this be recruited right now? Returns {"ok": bool, "code": Code,
## "message": String}. The message is written for the player, not the developer.
func can_recruit(settlement: Settlement, unit_type_id: String) -> Dictionary:
	if settlement == null or not units.has(unit_type_id):
		return _reject(Code.UNKNOWN_UNIT, "That kind of soldier cannot be recruited.")
	if state.current_settlement_id != settlement.id:
		return _reject(Code.NOT_AT_SETTLEMENT, "Travel to %s before recruiting." % settlement.name)
	if party_capacity_remaining() <= 0:
		return _reject(Code.PARTY_FULL, "Your party is full (%d)." % max_party_size())
	if available_at(settlement, unit_type_id) <= 0:
		return _reject(Code.POOL_EMPTY, "No %s are willing to join here right now." % _plural(unit_type_id))
	var cost := cost_for(unit_type_id)
	if state.player_gold < cost:
		return _reject(
			Code.NOT_ENOUGH_GOLD,
			"You need %d gold and have %d." % [cost, state.player_gold]
		)
	return {"ok": true, "code": Code.OK, "message": ""}


## How many of this archetype the player could currently afford and fit.
func affordable_count(settlement: Settlement, unit_type_id: String) -> int:
	if settlement == null or not units.has(unit_type_id):
		return 0
	var cost := cost_for(unit_type_id)
	var by_gold := int(state.player_gold / cost) if cost > 0 else available_at(settlement, unit_type_id)
	return maxi(0, mini(mini(by_gold, available_at(settlement, unit_type_id)), party_capacity_remaining()))


## ---------- the transaction ---------------------------------------------

## Recruit one soldier. Returns {"ok": bool, "code": Code, "message": String,
## "soldier": Soldier, "cost": int}.
func recruit(settlement: Settlement, unit_type_id: String) -> Dictionary:
	var check := can_recruit(settlement, unit_type_id)
	if not bool(check.get("ok", false)):
		return {
			"ok": false,
			"code": check.get("code", Code.BAD_REQUEST),
			"message": check.get("message", ""),
			"soldier": null,
			"cost": 0,
		}

	var cost := cost_for(unit_type_id)
	var index := state.peek_soldier_index()
	var rolled := factory.create(unit_type_id, index, settlement.name)
	var soldier := rolled.get("soldier", null) as Soldier
	if soldier == null:
		return {
			"ok": false,
			"code": Code.BAD_REQUEST,
			"message": "That soldier could not be created (%s)." % str(rolled.get("reason", "")),
			"soldier": null,
			"cost": 0,
		}

	# Money and roster move together from here on.
	state.player_gold -= cost
	state.register_soldier(soldier)
	state.player_party.add_member(soldier.id)
	settlement.recruit_pool[unit_type_id] = available_at(settlement, unit_type_id) - 1

	DebugLogger.info("recruited %s (%s, %d gold) at %s - %d gold remaining, %d/%d party" % [
		soldier.full_name(), units.display_name(unit_type_id), cost, settlement.name,
		state.player_gold, state.player_party.size(), max_party_size(),
	], "Recruitment")

	return {"ok": true, "code": Code.OK, "message": "", "soldier": soldier, "cost": cost}


## Recruit up to [param count], stopping at the first refusal.
## Returns {"ok": bool, "recruited": Array[Soldier], "spent": int, "message": String}.
func recruit_many(settlement: Settlement, unit_type_id: String, count: int) -> Dictionary:
	var wanted := clampi(count, 0, config.get_int("recruitment.max_recruit_batch", 20))
	var recruited: Array[Soldier] = []
	var spent := 0
	var message := ""
	for i in wanted:
		var result := recruit(settlement, unit_type_id)
		if not bool(result.get("ok", false)):
			message = str(result.get("message", ""))
			break
		recruited.append(result.get("soldier") as Soldier)
		spent += int(result.get("cost", 0))
	if recruited.is_empty() and message.is_empty():
		message = "Nothing was recruited."
	return {
		"ok": not recruited.is_empty(),
		"recruited": recruited,
		"spent": spent,
		"message": message,
	}


## ---------- helpers ------------------------------------------------------

func _plural(unit_type_id: String) -> String:
	var name := units.display_name(unit_type_id).to_lower()
	if name.ends_with("man"):
		return name.substr(0, name.length() - 3) + "men"
	if name.ends_with("s"):
		return name
	return name + "s"


func _reject(code: Code, message: String) -> Dictionary:
	return {"ok": false, "code": code, "message": message}
