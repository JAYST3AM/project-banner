class_name BattleArrows
extends RefCounted

## The arrows a battle has in the air: each one a straight run from where a shot was loosed to
## where it landed, over [constant FLIGHT] seconds.
##
## [b]Why a pool and not events.[/b] The compute battlefield reads no "who struck whom" out of its
## simulation - only a tally of the damage each soldier has dealt - so a shot is inferred the way
## the animation already infers a swing: a ranged soldier whose dealt-damage tally rose this pack
## loosed one, and it flies at the man he is already shooting at. The canvas battle gets the same
## picture from the simulator's own hit events ([method BattleView._launch_arrow]). Same look, same
## flight time, two renderers.
##
## Packed arrays rather than dictionaries: an arrow is three vectors and an age, this is drawn every
## frame a volley is in the air, and it is the style the unit batches beside it are written in.

## How long a shot takes from loosing to landing. Matches the canvas battle's ARROW_FLIGHT, so a
## volley reads the same in both renderers (and D-110: the damage number waits for the arrow).
const FLIGHT := 0.10
## Plenty for a volley. When it is full the oldest arrow is dropped rather than the newest: a
## missing shaft in a screen full of them is invisible, a shot that never appears reads as a unit
## that has stopped firing.
const CAP := 64


var _from := PackedVector2Array()
var _to := PackedVector2Array()
var _age := PackedFloat32Array()


## Loose one from [param from] to [param to].
func spawn(from: Vector2, to: Vector2) -> void:
	if _age.size() >= CAP:
		_from.remove_at(0)
		_to.remove_at(0)
		_age.remove_at(0)
	_from.append(from)
	_to.append(to)
	_age.append(0.0)


## Age every arrow by [param delta] and retire the ones that have landed. Compacts in place: the
## pool is at most [constant CAP] long and this runs once a frame.
func advance(delta: float) -> void:
	var keep := 0
	for i in _age.size():
		var age := _age[i] + delta
		if age >= FLIGHT:
			continue
		_age[keep] = age
		_from[keep] = _from[i]
		_to[keep] = _to[i]
		keep += 1
	if keep != _age.size():
		_from.resize(keep)
		_to.resize(keep)
		_age.resize(keep)


func clear() -> void:
	_from.clear()
	_to.clear()
	_age.clear()


func count() -> int:
	return _age.size()


func from_at(index: int) -> Vector2:
	return _from[index]


func to_at(index: int) -> Vector2:
	return _to[index]


## How far along its flight the arrow is: 0 just loosed, 1 landed.
func progress(index: int) -> float:
	return clampf(_age[index] / FLIGHT, 0.0, 1.0)


## Where its head has got to - the whole of what a draw needs besides the pool's own accessors.
func head_at(index: int) -> Vector2:
	return _from[index].lerp(_to[index], progress(index))
