class_name BattleAI
extends RefCounted
## Formation-level thinking.
##
## There is exactly one decision in here and it is made once per formation roughly
## twice a second: face the enemy and close with it. That is not a strategist and it is
## not meant to be one.
##
## What matters is [b]where the decision lives[/b]. Twenty thousand soldiers each
## running their own tactical planner is the architecture this project is deliberately
## avoiding. One order per formation, and then a great deal of cheap arithmetic as
## soldiers walk to the places they were given, is the architecture it is aiming at.
## This class exists to keep that boundary honest from the very first AI.
##
## The AI is deliberately not called by [BattleSimulator] itself. Whoever owns the
## battle loop calls [method update] - the scene does, the benchmark does, the tests
## do. A simulator with no AI attached is a simulator where nothing moves on its own,
## which is what most of the tests want.

const DEFAULT_INTERVAL := 0.5
const DEFAULT_CONTACT_GAP := 1.5

## Which side this AI gives orders to. Symmetric on purpose: the enemy uses the same
## formations, the same geometry and the same orders the player does.
var side: String = BattleContext.SIDE_ENEMY
var interval: float = DEFAULT_INTERVAL
## The gap the formation closes to, measured between the two bodies' nearest edges
## rather than between their centres, so a deep column and a shallow line stop at the
## same distance from contact.
var contact_gap: float = DEFAULT_CONTACT_GAP

var _timer: float = 0.0
## Orders issued so far - the benchmark and the tests use it to show the AI is
## actually doing something rather than being silently inert.
var orders_issued: int = 0


static func create(config: GameConfig, p_side: String = BattleContext.SIDE_ENEMY) -> BattleAI:
	var ai := BattleAI.new()
	ai.side = p_side
	if config != null:
		ai.interval = maxf(0.05, config.get_float("formation.enemy_think_interval", DEFAULT_INTERVAL))
		ai.contact_gap = maxf(0.0, config.get_float("formation.enemy_contact_gap", DEFAULT_CONTACT_GAP))
	return ai


## Give this side's formations their orders. Throttled: thinking every tick would be
## waste, and an order that changes eighty times a second is not an order.
func update(simulator: BattleSimulator, delta: float) -> void:
	if simulator == null or simulator.formations.is_empty():
		return
	_timer += delta
	if _timer < interval:
		return
	_timer = 0.0
	issue_orders(simulator)


## One round of thinking, ignoring the throttle. Exposed so tests can drive it
## deterministically instead of waiting on wall-clock time.
func issue_orders(simulator: BattleSimulator) -> void:
	if simulator == null:
		return
	var units_by_id := simulator.units_by_id()
	for formation in simulator.formations:
		if formation.side != side:
			continue
		# A body with nobody left standing is not a body. Ordering one is at best
		# pointless and at worst makes the AI look like it is doing something while its
		# army is already gone.
		if not formation.has_living_units(units_by_id):
			continue
		var target := _nearest_enemy_formation(simulator, formation)
		if target == null:
			continue
		_order_against(formation, target)


func _order_against(formation: BattleFormation, target: BattleFormation) -> void:
	# Face the enemy, and mean it. Facing is a decision, not a mechanic: the body turns
	# toward it over the next second or two at its own turn rate, which is the part
	# that has to be earned.
	formation.order_face_toward(target.anchor)
	# Then say what the body is for. Closing the distance is not decided here - the
	# battlefield works that out each step, because it is the only thing that knows
	# where everyone is standing. This says only "go and fight", which is what makes it
	# an order rather than a script.
	formation.order_engage()
	orders_issued += 1


## Closest opposing formation by centre. A linear scan: there are a handful of
## formations, never thousands, so there is nothing here worth indexing.
func _nearest_enemy_formation(simulator: BattleSimulator, formation: BattleFormation) -> BattleFormation:
	var units_by_id := simulator.units_by_id()
	var best: BattleFormation = null
	var best_distance := INF
	for candidate in simulator.formations:
		# Two different questions that look like one. "Is this body empty" asks whether
		# it has ever been given anybody; a body that has been wiped out still holds
		# every id it ever had, because casualties are kept on the roll on purpose so
		# that a gap in the line stays a gap. "Does this body have anybody left
		# standing" is the question that matters here, and it is asked through the same
		# method the battlefield uses, so there is one definition of an active body
		# rather than two that can drift apart. See D-055.
		if candidate.side == formation.side or not candidate.has_living_units(units_by_id):
			continue
		var distance := formation.anchor.distance_to(candidate.anchor)
		if distance < best_distance:
			best_distance = distance
			best = candidate
	return best
