class_name BattleClock
extends RefCounted
## The bridge between rendered frames and simulation ticks.
##
## [b]What it is for.[/b] The battle scene used to hand the simulator whatever time the last
## rendered frame happened to take - a fast machine ran a 0.008-second step and a slow one a
## 0.05-second step - so the same seed, the same orders and the same army produced a
## different battle on a different machine. Frames are a property of the hardware and the
## monitor; they have no business deciding a fight. See D-103.
##
## [b]How it works.[/b] Real frame time goes in, whole simulation ticks come out. The
## accumulator holds the fraction that is not yet a whole tick, so the simulation is always
## advanced by the same step, and a frame that took twice as long runs twice as many ticks
## rather than one tick of twice the size. Simulation time therefore still tracks wall time on
## average, while the sequence of simulated states depends on the tick number alone.
##
## [b]It is deliberately not a renderer.[/b] Nothing here interpolates or extrapolates: a
## frame draws the latest state the simulation reached. Drawing between two states is a look,
## not a correctness question, and it belongs to the milestone that adds it.
##
## [b]The catch-up cap is what stops the spiral.[/b] A quarter-second frame may not ask for a
## quarter second of simulation to be caught up for ever - the work of catching up would make
## the next frame later still. One frame runs at most [member max_catch_up] ticks, and a
## backlog beyond [member max_backlog] seconds is dropped rather than queued. The simulation
## is unaffected by that; a machine that cannot keep up sees the battle take longer in real
## time, which is the honest failure mode, instead of a machine-dependent battle.

## The simulation rate assumed when nothing better is configured. Matches
## [code]battle.tick_rate[/code] in the game data, and is the step every benchmark, showcase
## and suite in this repository was measured with.
const DEFAULT_RATE := 20.0
## How many ticks one rendered frame may run. Eight is about a quarter of a second of
## simulation, which is as far behind as a battle is allowed to fall in a single frame.
const DEFAULT_MAX_CATCH_UP := 8
## How much un-run time may pile up before it is thrown away instead.
const DEFAULT_MAX_BACKLOG := 0.5

## Seconds of simulation per tick. Fixed for the life of the clock.
var step: float = 1.0 / DEFAULT_RATE
var max_catch_up: int = DEFAULT_MAX_CATCH_UP
var max_backlog: float = DEFAULT_MAX_BACKLOG

## Time that has been given to the clock but has not yet become a whole tick.
var pending: float = 0.0
## Seconds of simulation time that were dropped because this machine could not keep up.
## Development and reporting only: nothing in the game reads it.
var dropped: float = 0.0


## A clock for a battle configured by the game data. The rate lives in the data because a
## tick is a design decision, not a rendering one.
static func create(config: GameConfig = null) -> BattleClock:
	var clock := BattleClock.new()
	var rate := DEFAULT_RATE
	if config != null:
		rate = config.get_float("battle.tick_rate", DEFAULT_RATE)
	clock.set_rate(rate)
	return clock


func set_rate(rate: float) -> void:
	# A rate of zero or less would be an infinite step, which is not a clock. Repaired
	# rather than honoured, like every other numeric boundary in this project.
	var safe := rate if rate > 0.0 else DEFAULT_RATE
	step = 1.0 / safe


## Ticks per second of simulation.
func rate() -> float:
	return 1.0 / step


## Record one rendered frame and return how many simulation ticks are now due.
##
## [param frame_delta] is real seconds since the last frame; [param speed] is the player's
## time multiplier, which buys more ticks per frame rather than a longer tick - the difference
## between a battle running faster and a battle being simulated differently.
func frame(frame_delta: float, speed: float = 1.0) -> int:
	if frame_delta > 0.0 and speed > 0.0:
		pending += frame_delta * speed
	if pending > max_backlog:
		dropped += pending - max_backlog
		pending = max_backlog
	var due := int(floor(pending / step))
	if due > max_catch_up:
		var skipped := float(due - max_catch_up)
		dropped += skipped * step
		pending -= skipped * step
		due = max_catch_up
	pending = maxf(0.0, pending - float(due) * step)
	return due


## Forget everything that has not yet been run. Called when a battle starts, so that a pause
## spent in a menu is not simulated the moment the fighting begins.
func reset() -> void:
	pending = 0.0
	dropped = 0.0


## What the bridge did, for the overlay and the report. Development-only.
func report() -> Dictionary:
	return {
		"step": step,
		"rate": rate(),
		"pending": pending,
		"dropped_seconds": dropped,
		"max_catch_up": max_catch_up,
		"max_backlog": max_backlog,
	}
