class_name BattleJournal
extends RefCounted
## A dev-only journal of the transitions that decide a long battle.
##
## [b]Why it exists.[/b] A battle that has frozen looks, in a log that only carries blows and
## deaths, exactly like a battle that is thinking. The transitions that tell the two apart - a
## body gaining or losing contact, a body finding a different enemy, an army passing a casualty
## milestone, the clock running out - are not written anywhere. This writes them, and only them:
## a hundred lines for a six-hundred-soldier battle, rather than the five thousand a per-blow log
## would need.
##
## [b]Off unless asked for.[/b] Nothing constructs a journal unless a run asks for one
## ([code]--battlelog[/code], or [code]--battlelog=<path>[/code]), so release play writes nothing
## to disk. Its lines go through [DebugLogger] - the project's one logging funnel - and this class
## subscribes to that funnel and appends the battle's own entries to a file. There is no second
## logger here.
##
## Battle time in the file is counted at the battle's own fixed step, taken from the battle's
## configuration - whether or not the run that produced it was driven at that step.

const CATEGORY := "Battle"
## Where a journal goes when the flag gives no path of its own.
const DEFAULT_PATH := "user://battle_journal.log"
## How often the body-to-body picture is re-scanned. Finding which body a body is nearest to is a
## few hundred comparisons at the body counts this game fights at, and it is not a per-tick
## question.
const SCAN_INTERVAL := 25
## How often the journal says where the battle stands even when nothing has happened. A journal
## that goes quiet for a thousand ticks should say so with a line rather than with silence.
const STEADY_INTERVAL := 1500

var path := ""

var _file: FileAccess = null
var _lines := 0
var _started := false
var _finished := false
var _contact: Dictionary = {}
var _nearest: Dictionary = {}
var _next_scan := 0
var _next_steady := 0
var _milestones := 0
var _seed := 0
## Seconds one tick of this battle represents, from the battle's own configuration.
var _step := 0.05


## Open a journal. Pass a path, or an empty string for [constant DEFAULT_PATH]. Returns null - and
## a warning - when the file cannot be written, because a run should never fail over its own
## instrumentation.
static func open(path_value: String = "") -> BattleJournal:
	var journal := BattleJournal.new()
	journal.path = path_value if path_value != "" else DEFAULT_PATH
	journal._file = FileAccess.open(journal.path, FileAccess.WRITE)
	if journal._file == null:
		push_warning("battle journal could not open %s" % journal.path)
		return null
	DebugLogger.logged.connect(journal._on_logged)
	journal._lines += 1
	journal._file.store_line("battle journal: %s" % journal.path)
	return journal


## Close the journal and stop mirroring the log funnel. Safe to call more than once.
func close() -> void:
	if _file == null:
		return
	if DebugLogger.logged.is_connected(_on_logged):
		DebugLogger.logged.disconnect(_on_logged)
	_file.store_line("%d lines written" % _lines)
	_file.flush()
	_file.close()
	_file = null


func lines_written() -> int:
	return _lines


## What battle this is. Called once, before the first tick.
func note_start(simulator: BattleSimulator, seed_value: int) -> void:
	_seed = seed_value
	_started = true
	if simulator.config != null:
		_step = 1.0 / maxf(1.0, simulator.config.get_float("battle.tick_rate", 20.0))
	note(-1, "battle start: seed %d, %d soldiers in %d bodies, field %.0fx%.0f, clock %.0fs" % [
		seed_value, simulator.units.size(), simulator.formations.size(),
		simulator.field_size.x, simulator.field_size.y, simulator.max_duration])


## Once a tick. Reports contact transitions, casualty milestones, which body each body is facing,
## and the moment the battle ends.
func observe(simulator: BattleSimulator) -> void:
	if _file == null or not _started or _finished:
		return
	var tick := simulator.tick_index

	# Contact, which is the whole question in a long battle: a body losing it, and taking it back.
	for body in simulator.formations:
		var had: bool = _contact.get(body.id, false)
		if body.in_contact != had:
			_contact[body.id] = body.in_contact
			note(tick, "%s %s contact, %d of its men alive" % [
				body.id, "gained" if body.in_contact else "lost", body.living_count])

	# Casualties, at each tenth of the battle's starting strength.
	var living := simulator.alive_units().size()
	var down := simulator.units.size() - living
	var milestone := down * 10 / maxi(1, simulator.units.size())
	if milestone > _milestones:
		_milestones = milestone
		note(tick, "%d of %d down: %d player and %d enemy still standing" % [
			down, simulator.units.size(),
			simulator.side_count(BattleContext.SIDE_PLAYER),
			simulator.side_count(BattleContext.SIDE_ENEMY)])

	# Which enemy body each body is nearest to. A body that changes its answer has moved on.
	if tick >= _next_scan:
		_next_scan = tick + SCAN_INTERVAL
		_scan_bodies(simulator, tick)

	if tick >= _next_steady:
		_next_steady = tick + STEADY_INTERVAL
		note(tick, "still fighting: %d v %d at %.0fs, %d bodies in contact" % [
			simulator.side_count(BattleContext.SIDE_PLAYER),
			simulator.side_count(BattleContext.SIDE_ENEMY),
			simulator.elapsed, _in_contact_count(simulator)])

	if simulator.is_finished():
		_finish_lines(simulator)


## ---------- internals ----------------------------------------------------

func _in_contact_count(simulator: BattleSimulator) -> int:
	var count := 0
	for body in simulator.formations:
		if body.in_contact:
			count += 1
	return count


## Nearest living enemy body for each of our bodies, by anchor distance - which is the honest
## approximation of "the body it is fighting", and costs nothing at these body counts.
func _scan_bodies(simulator: BattleSimulator, tick: int) -> void:
	for body in simulator.formations:
		var best := ""
		var best_distance := INF
		for other in simulator.formations:
			if other.side == body.side or other.living_count <= 0:
				continue
			var distance: float = body.anchor.distance_to(other.anchor)
			if distance < best_distance:
				best_distance = distance
				best = other.id
		var had: String = _nearest.get(body.id, "")
		if best == "":
			if had != "":
				_nearest[body.id] = ""
				note(tick, "%s has no living enemy body left to face" % body.id)
			continue
		if had != best:
			_nearest[body.id] = best
			note(tick, "%s is nearest to %s, %.1f units away" % [body.id, best, best_distance])


func _finish_lines(simulator: BattleSimulator) -> void:
	_finished = true
	if simulator.winner != "":
		note(simulator.tick_index, "battle finished: %s wins after %.1fs, %d player and %d enemy standing" % [
			simulator.winner, simulator.elapsed,
			simulator.side_count(BattleContext.SIDE_PLAYER),
			simulator.side_count(BattleContext.SIDE_ENEMY)])
	else:
		note(simulator.tick_index, "clock expired at %.1fs with both armies on the field: %d v %d, %d bodies in contact" % [
			simulator.elapsed,
			simulator.side_count(BattleContext.SIDE_PLAYER),
			simulator.side_count(BattleContext.SIDE_ENEMY), _in_contact_count(simulator)])


## Mirror the project's own battle-log entries into the file, so a run's Diagnostics tab and its
## journal do not tell different stories.
func _on_logged(entry: Dictionary) -> void:
	if _file == null or _finished or str(entry.get("category", "")) != CATEGORY:
		return
	_file.store_line("        %s" % str(entry.get("message", "")))
	_lines += 1


## A line of the journal's own: written to the file, and put through the funnel so that a headless
## run's stdout tells the same story as the file.
func note(tick: int, message: String) -> void:
	if _file == null:
		return
	var stamp := "          " if tick < 0 else "t=%6d %6.2fs" % [tick, float(tick) * _step]
	_file.store_line("%s  %s" % [stamp, message])
	# A journal is read after a run, and runs get killed: what has been said should be on disk
	# whether or not anybody closed the file. Lines are rare - transitions and milestones.
	_file.flush()
	_lines += 1
	DebugLogger.info(message, CATEGORY)
