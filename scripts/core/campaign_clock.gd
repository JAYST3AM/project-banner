class_name CampaignClock
extends RefCounted
## Campaign date/time and time-scale control.
##
## All real-seconds-to-game-hours conversion lives here so that no movement or
## AI code ever embeds a magic conversion constant.

enum Speed { PAUSED = 0, NORMAL = 1, FAST = 2 }

const SPEED_NAMES: Array[String] = ["Paused", "Normal", "Fast"]

var config: GameConfig

var day: int = 1
var hour: float = 8.0
var speed: Speed = Speed.NORMAL

## Speed to return to when unpausing, so the spacebar restores the pace the
## player had chosen rather than silently dropping back to normal.
var resume_speed: Speed = Speed.NORMAL

var hours_per_day: float = 24.0
var seconds_per_game_hour: float = 2.0
var speed_multipliers: Dictionary = {"paused": 0.0, "normal": 1.0, "fast": 3.0}


func _init(p_config: GameConfig = null) -> void:
	config = p_config
	apply_config()


## (Re)read tuning values from the config. Safe to call before [member config] is set.
func apply_config() -> void:
	if config == null:
		return
	hours_per_day = maxf(1.0, config.get_float("time.hours_per_day", 24.0))
	seconds_per_game_hour = maxf(0.0001, config.get_float("time.seconds_per_game_hour", 2.0))
	speed_multipliers = config.get_dict("time.speed_multipliers", speed_multipliers)


func multiplier() -> float:
	match speed:
		Speed.PAUSED:
			return 0.0
		Speed.FAST:
			return float(speed_multipliers.get("fast", 3.0))
		_:
			return float(speed_multipliers.get("normal", 1.0))


func is_paused() -> bool:
	return speed == Speed.PAUSED


func set_speed(new_speed: Speed) -> void:
	if new_speed != Speed.PAUSED:
		resume_speed = new_speed
	speed = new_speed


func set_speed_by_name(speed_name: String) -> bool:
	var wanted := speed_name.strip_edges().to_lower()
	for i in SPEED_NAMES.size():
		if SPEED_NAMES[i].to_lower() == wanted:
			set_speed(i as Speed)
			return true
	return false


func speed_name() -> String:
	return SPEED_NAMES[int(speed)]


func toggle_pause() -> void:
	set_speed(resume_speed if speed == Speed.PAUSED else Speed.PAUSED)


## Add game hours directly (used when a system knows the duration exactly).
func advance_hours(hours: float) -> void:
	if hours <= 0.0:
		return
	hour += hours
	while hour >= hours_per_day:
		hour -= hours_per_day
		day += 1


## Convert real frame time into game time using the current speed, then advance.
## Returns the game hours actually advanced (0.0 while paused).
func advance_real_seconds(real_seconds: float) -> float:
	var mult := multiplier()
	if mult <= 0.0 or real_seconds <= 0.0:
		return 0.0
	var game_hours := (real_seconds * mult) / seconds_per_game_hour
	advance_hours(game_hours)
	return game_hours


func total_hours() -> float:
	return (float(day - 1) * hours_per_day) + hour


func time_string() -> String:
	return CampaignClock.time_string_from_hour(hour)


## Static form so UI can format a saved hour without building a clock.
static func time_string_from_hour(value: float) -> String:
	var h := int(floor(value))
	var m := int(floor((value - float(h)) * 60.0))
	return "%02d:%02d" % [clampi(h, 0, 23), clampi(m, 0, 59)]


func day_string() -> String:
	return "Day %d" % day


func full_string() -> String:
	return "%s - %s" % [day_string(), time_string()]


func to_dict() -> Dictionary:
	return {
		"day": day,
		"hour": hour,
		"speed": int(speed),
		"resume_speed": int(resume_speed),
	}


func from_dict(data: Dictionary) -> void:
	day = int(data.get("day", 1))
	hour = float(data.get("hour", 8.0))
	speed = int(data.get("speed", int(Speed.NORMAL))) as Speed
	resume_speed = int(data.get("resume_speed", int(Speed.NORMAL))) as Speed
	if resume_speed == Speed.PAUSED:
		resume_speed = Speed.NORMAL


func copy_from(other: CampaignClock) -> void:
	day = other.day
	hour = other.hour
	speed = other.speed
	resume_speed = other.resume_speed
