class_name DevFlags
extends RefCounted
## Command-line switches for development and automated verification.
##
## These are the only way to get into gameplay without touching the mouse, which
## makes "does the real, rendered world map actually work?" testable:
##
## [codeblock]
## godotc --path "<project>" -- --autostart-campaign=999 --autotravel=brackenford
## [/codeblock]
##
## Everything here is inert unless the matching argument is passed, so shipping
## builds behave normally. Debug-only UI is gated separately by
## [code]debug.enabled[/code] in the config.

const AUTOSTART_PREFIX := "--autostart-campaign"
const AUTOTRAVEL_PREFIX := "--autotravel="
const AUTOTOWN_PREFIX := "--autostart-town="
const AUTORECRUIT_PREFIX := "--autorecruit="
const AUTOENGAGE_FLAG := "--autoengage"
const AUTOATTACK_FLAG := "--autoattack"
const AUTOLEAVE_FLAG := "--autoleave"
const AUTOSTART_BATTLE_FLAG := "--autostart-battle"
## Frame pacing on the record: "--framelog" logs the frame rate, frame-time mean and worst, and any
## hitch the moment it happens. A frame rate you can grep beats one you have to watch.
const FRAMELOG_FLAG := "--framelog"
## Start with the developer's furniture showing: the debug panel (with its priced-grid overlay) and
## the frame-rate overlay. F1 toggles them by hand; a script and a screenshot cannot press a key,
## and "show me the debug grid" is a request that arrives as one.
const DEBUG_PANEL_FLAG := "--debug-panel"
## Hover, not click: "--hover-card" (or "--hover-card=<settlement id>") shows the settlement detail
## card at boot, for a scripted run or a screenshot. Bare, it picks the nearest visited settlement,
## falling back to the nearest of any kind.
const HOVER_CARD_FLAG := "--hover-card"
const HOVER_CARD_PREFIX := "--hover-card="
## Open the settings panel straight away, because a screenshot cannot click the button that opens it.
const SETTINGS_PANEL_FLAG := "--settings-panel"
## Force a UI scale for one run: "--ui-scale=1.2". Wins over the saved file, because it is the more
## deliberate request, and it is how screenshots at other scales are taken.
const UI_SCALE_PREFIX := "--ui-scale="
## Move the scale at runtime, four seconds in: "--ui-scale-late=0.6". Verifies that a committed
## change reaches screens that are already built.
const UI_SCALE_LATE_PREFIX := "--ui-scale-late="
## Save one PNG of the game's own window and (optionally) quit: "--screenshot=<path>", with
## "--screenshot-delay=<ms>" and "--screenshot-quit". The game draws into its own viewport, so a
## verification shot never depends on the window being on top of anything.
const SCREENSHOT_PREFIX := "--screenshot="
const SCREENSHOT_DELAY_PREFIX := "--screenshot-delay="
const SCREENSHOT_QUIT_FLAG := "--screenshot-quit"
## How long after boot a screenshot waits for the scene to finish arriving, when not told otherwise.
const SCREENSHOT_DELAY_DEFAULT_MS := 2500
## A dev run's own log file name: "--log-name=dev" writes user://logs/dev.log instead of the
## player's session.log, so check-runs never rotate or clobber a live play session's log.
const LOG_NAME_PREFIX := "--log-name="
## Run a scripted formation drill through the battle scene's real order methods.
const AUTOFORMATIONS_FLAG := "--autoformations"
const BATTLESPEED_PREFIX := "--battlespeed="
## Dev-only battle journal: "--battlelog" for the default file, "--battlelog=<path>" to name one.
const BATTLELOG_FLAG := "--battlelog"
const BATTLELOG_PREFIX := "--battlelog="


static func _user_args() -> PackedStringArray:
	return OS.get_cmdline_user_args()


## Returns {"enabled": bool, "name": String, "seed": int}.
static func autostart_campaign() -> Dictionary:
	var result := {"enabled": false, "name": "Dev Campaign", "seed": 0}
	for arg in _user_args():
		if arg == AUTOSTART_PREFIX or arg.begins_with(AUTOSTART_PREFIX + "="):
			result["enabled"] = true
			var value := arg.trim_prefix(AUTOSTART_PREFIX).trim_prefix("=")
			if not value.is_empty():
				result["name"] = "Dev Campaign %s" % value
				result["seed"] = int(value) if value.is_valid_int() else RngService.stable_hash(value)
			return result
	# Also honoured as a plain (non user) argument, so `godot --autostart-campaign`
	# works without the `--` separator.
	for arg in OS.get_cmdline_args():
		if arg == AUTOSTART_PREFIX or arg.begins_with(AUTOSTART_PREFIX + "="):
			result["enabled"] = true
			var raw := arg.trim_prefix(AUTOSTART_PREFIX).trim_prefix("=")
			if not raw.is_empty():
				result["name"] = "Dev Campaign %s" % raw
				result["seed"] = int(raw) if raw.is_valid_int() else RngService.stable_hash(raw)
			return result
	return result


## Settlement id the party should immediately set out for, or "".
static func autotravel_destination() -> String:
	for arg in _user_args():
		if arg.begins_with(AUTOTRAVEL_PREFIX):
			return arg.trim_prefix(AUTOTRAVEL_PREFIX)
	return ""


## Settlement id to jump straight into on world-map load, or "". Consumed once:
## after the first use it returns "" so an automated run does not loop back into
## the town every time the world map reloads.
static var _town_consumed: bool = false


static func consume_autostart_town() -> String:
	if _town_consumed:
		return ""
	for arg in _user_args():
		if arg.begins_with(AUTOTOWN_PREFIX):
			_town_consumed = true
			return arg.trim_prefix(AUTOTOWN_PREFIX)
	return ""


## How many soldiers to recruit automatically (through the real UI handler) the
## moment a settlement screen opens. 0 = off.
static func autorecruit_count() -> int:
	for arg in _user_args():
		if arg.begins_with(AUTORECRUIT_PREFIX):
			var raw := arg.trim_prefix(AUTORECRUIT_PREFIX)
			return int(raw) if raw.is_valid_int() else 0
	return 0


## Jump the player straight onto the nearest hostile party so an encounter fires.
static func autoengage() -> bool:
	return _has_flag(AUTOENGAGE_FLAG)


## Start with the developer's furniture on screen - the debug panel and the frame-rate overlay -
## for a scripted run or a screenshot that cannot press F1.
static func debug_panel() -> bool:
	return _has_flag(DEBUG_PANEL_FLAG)


## "--hover-card" for the nearest visited settlement, "--hover-card=<id>" for a named one, "" for
## no request.
static func hover_card() -> String:
	for arg in _user_args():
		if arg == HOVER_CARD_FLAG:
			return "nearest"
		if arg.begins_with(HOVER_CARD_PREFIX):
			return arg.substr(HOVER_CARD_PREFIX.length())
	return ""


## Whether a run asked to start with the settings panel open.
static func settings_panel() -> bool:
	return _has_flag(SETTINGS_PANEL_FLAG)


## The UI scale a run asked for, or 0.0 when it did not.
static func ui_scale() -> float:
	for arg in _user_args():
		if arg.begins_with(UI_SCALE_PREFIX):
			return float(arg.substr(UI_SCALE_PREFIX.length()))
	return 0.0


## The UI scale a run asked to switch to after boot, or 0.0 when it did not.
static func ui_scale_late() -> float:
	for arg in _user_args():
		if arg.begins_with(UI_SCALE_LATE_PREFIX):
			return float(arg.substr(UI_SCALE_LATE_PREFIX.length()))
	return 0.0


## Where a run asked to save one screenshot of its own window, or "" when it did not.
static func screenshot_path() -> String:
	for arg in _user_args():
		if arg.begins_with(SCREENSHOT_PREFIX):
			return arg.substr(SCREENSHOT_PREFIX.length())
	return ""


## How long that screenshot should wait after boot, in milliseconds.
static func screenshot_delay_ms() -> int:
	for arg in _user_args():
		if arg.begins_with(SCREENSHOT_DELAY_PREFIX):
			return int(arg.substr(SCREENSHOT_DELAY_PREFIX.length()))
	return SCREENSHOT_DELAY_DEFAULT_MS


## Whether a run wants the game to quit once the screenshot is on disk.
static func screenshot_quit() -> bool:
	return _has_flag(SCREENSHOT_QUIT_FLAG)


## The log file name a run asked for, or "" for the player's own session log.
static func log_name() -> String:
	for arg in _user_args():
		if arg.begins_with(LOG_NAME_PREFIX):
			return arg.substr(LOG_NAME_PREFIX.length())
	return ""


## Accept the first encounter prompt automatically instead of waiting for a click.
static func autoattack() -> bool:
	return _has_flag(AUTOATTACK_FLAG)


## Leave a settlement immediately after the automatic recruitment, so an
## automated run can chain town -> world map -> encounter -> battle.
static func autoleave_town() -> bool:
	return _has_flag(AUTOLEAVE_FLAG)


## Begin the battle the moment the battlefield loads.
static func autostart_battle() -> bool:
	return _has_flag(AUTOSTART_BATTLE_FLAG)


## Exercise the player's formation commands automatically once the battle is running.
##
## This drives the same methods the keyboard and the HUD buttons drive - selecting,
## re-shaping, detaching, moving, turning, and the debug overlay - because the point of
## an automated run is to exercise the real control path rather than a parallel one
## that only exists for testing. It exists so that a windowed smoke run can cover the
## commands a player would give, which a headless suite cannot claim to have done.
static func autoformations() -> bool:
	return _has_flag(AUTOFORMATIONS_FLAG)


## Multiplier applied to battle time, so an automated run does not have to sit
## through a real-time fight. 1.0 = normal.
static func battle_speed() -> float:
	for arg in _user_args():
		if arg.begins_with(BATTLESPEED_PREFIX):
			var raw := arg.trim_prefix(BATTLESPEED_PREFIX)
			var value := float(raw) if raw.is_valid_float() else 1.0
			return clampf(value, 0.1, 200.0)
	return 1.0


## Whether this run asked for a battle journal. Nothing writes one unless this is true:
## a long battle is exactly the case where a log is worth having, and exactly the case
## where a game that writes one unasked would fill a player's disk.
static func battle_log_requested() -> bool:
	return _has_flag(BATTLELOG_FLAG)


## Whether this run wants frame pacing written to the log.
static func framelog() -> bool:
	return _has_flag(FRAMELOG_FLAG)


## Where the battle journal should go, or "" for the journal's own default. Meaningless
## unless [method battle_log_requested] is true.
static func battle_log_path() -> String:
	for arg in _user_args():
		if arg.begins_with(BATTLELOG_PREFIX):
			return arg.trim_prefix(BATTLELOG_PREFIX)
	for arg in OS.get_cmdline_args():
		if arg.begins_with(BATTLELOG_PREFIX):
			return arg.trim_prefix(BATTLELOG_PREFIX)
	return ""


static func _has_flag(flag: String) -> bool:
	for arg in _user_args():
		if arg == flag or arg.begins_with(flag + "="):
			return true
	for arg in OS.get_cmdline_args():
		if arg == flag or arg.begins_with(flag + "="):
			return true
	return false
