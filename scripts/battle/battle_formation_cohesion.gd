class_name BattleFormationCohesion
extends RefCounted
## Throttles only explicit formation marches when soldiers are significantly
## behind their assigned slots. Does not affect combat press, hold, damage,
## target selection, or the unchanged GPU stress-probe baseline.
##
## The input is the average *measured* soldier-to-slot error from the existing
## GPU state readback (not an invented morale or animation value). No added
## per-agent CPU loop or extra GPU readback is needed.
const FREE_SPACING := 0.8
const STOP_SPACING := 3.0


static func march_multiplier(mean_slot_error: float, spacing: float) -> float:
	var gap := maxf(0.1, spacing)
	var error := maxf(0.0, mean_slot_error)
	var free := gap * FREE_SPACING
	var stop := gap * STOP_SPACING
	if error <= free:
		return 1.0
	if error >= stop:
		return 0.0
	return clampf((stop - error) / (stop - free), 0.0, 1.0)
