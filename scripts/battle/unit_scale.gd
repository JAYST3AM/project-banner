class_name UnitScale
extends RefCounted

## The sizes a battle is counted in, and drawn at.
##
## [b]Why Roman.[/b] These are the names soldiers actually counted themselves in, and each one is a
## size rather than a flourish: the contubernium was the eight men who shared a tent, the century
## was the smallest body that fought as one thing, the cohort was the smallest that could be
## detached and still hold a line, and the legion was a field army. They are also the ladder the
## simulation wants: a group is the unit of display [i]and[/i] the unit of computation, because a
## hundred men sharing a place and a task are doing the same arithmetic a hundred times.
##
## [b]Display and computation are the same grouping.[/b] Whatever box is drawn is also the group
## whose soldiers would be worked out once - the same numbers, not an approximation of them.

## The eight men of one tent: the smallest group a soldier belongs to.
const CONTUBERNIUM := 8
## The smallest body that fights as one: the game's existing formation size.
const CENTURY := 100
## Six centuries: the smallest body that can be detached and still hold.
const COHORT := 480
## Ten cohorts: a field army.
const LEGION := 5000

## How much of the battle is drawn as one mark.
enum Level {
	SOLDIER, ## One mark a man: only when the camera is close enough for a man to be a man.
	CONTUBERNIUM,
	CENTURY,
	COHORT,
	LEGION,
}

## Soldiers in one mark at each level.
const SIZES := {
	Level.CONTUBERNIUM: CONTUBERNIUM,
	Level.CENTURY: CENTURY,
	Level.COHORT: COHORT,
	Level.LEGION: LEGION,
}

## Below this zoom a man is smaller than a mark worth drawing, so the group is drawn instead.
const SOLDIER_ZOOM := 6.0
## Centures hold until the camera can see a whole cohort of them without crowding.
const CENTURY_ZOOM := 1.5
## Cohorts hold until a legion fits on the screen.
const COHORT_ZOOM := 0.6


## The level a camera at [param zoom] should be drawn at. The thresholds are zooms rather than world
## sizes because what matters is how much screen a mark of a given size would cover, and the
## camera's zoom is exactly that.
static func level_for_zoom(zoom: float) -> int:
	if zoom >= SOLDIER_ZOOM:
		return Level.SOLDIER
	if zoom >= CENTURY_ZOOM:
		return Level.CENTURY
	if zoom >= COHORT_ZOOM:
		return Level.COHORT
	return Level.LEGION


## Soldiers in one mark at [param level]. A soldier is his own mark, so his size is one.
static func size_of(level: int) -> int:
	return int(SIZES.get(level, 1))


## The name of the level, for labels and reports.
static func name_of(level: int) -> String:
	match level:
		Level.SOLDIER:
			return "soldier"
		Level.CONTUBERNIUM:
			return "contubernium"
		Level.CENTURY:
			return "century"
		Level.COHORT:
			return "cohort"
		Level.LEGION:
			return "legion"
	return "soldier"


## Whether this level draws the soldiers themselves rather than a group mark.
static func is_single(level: int) -> bool:
	return level == Level.SOLDIER
