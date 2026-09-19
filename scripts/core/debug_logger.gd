extends Node
## DebugLogger (autoload).
##
## Single logging funnel for the whole project. Runtime output is timestamped,
## categorised and kept in a small in-memory ring buffer so the debug panel can
## show recent history without a log file.

signal logged(entry: Dictionary)

enum Level { DEBUG = 0, INFO = 1, WARN = 2, ERROR = 3 }

const LEVEL_NAMES: Array[String] = ["DEBUG", "INFO", "WARN", "ERROR"]
const RING_SIZE := 300

var min_level: Level = Level.DEBUG
## Off by default: a console build's print is a synchronous write and the plain Windows build has no
## usable stdout at all, so the file below is the log that matters. Turn this on only for a run whose
## output is being piped somewhere on purpose.
var echo_to_stdout: bool = false
## Where the session's log goes. Under user://, which is
## %APPDATA%/Godot/app_userdata/Project Banner/ on Windows - so it can be tailed or grepped while the
## game is running, without a console window and without redirecting stdout.
const LOG_DIR := "user://logs"
const LOG_FILE := "user://logs/session.log"
## Lines are held in memory and written in one go: a write per line is the thing that was slow.
const FLUSH_EVERY_MS := 1000
## When the buffer grows past this without a flush, write it anyway so a crash cannot lose the story.
const FLUSH_AT_LINES := 120

var _pending: PackedStringArray = []
var _log_handle: FileAccess = null
var _last_flush_ms := 0
var _log_path := ""
## A line identical to the one before it, inside this window, is dropped rather than written again.
## The owner's report was that logging froze the game, and the arithmetic agrees: a frame-rate line
## asks to be written five times a second, a console build's print is a synchronous write, and the
## HUD's own readout was going out through it every half second per run. Throttling repeats is what
## makes a logger safe to leave switched on.
const REPEAT_WINDOW_MS := 250

var _ring: Array[Dictionary] = []
var _last_message := ""
var _last_at_ms := 0


func _ready() -> void:
	# Logging must keep working while gameplay is paused.
	process_mode = Node.PROCESS_MODE_ALWAYS
	# Globalized on purpose: the *absolute* variant of this call wants a real path, and handing it a
	# user:// one fails quietly - which it did, and the sink wrote nothing.
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(LOG_DIR))
	# The log is one session deep, and WRITE truncates: every run used to destroy the previous one -
	# which cost the owner a whole play session's evidence when a suite started beside his running
	# game ("check the logs" and the log no longer held his play). Rotate instead, keeping exactly
	# one previous session beside it, so "what did the last run do" is always answerable.
	var absolute := ProjectSettings.globalize_path(LOG_FILE)
	if FileAccess.file_exists(absolute):
		var previous := absolute.get_basename() + ".prev.log"
		if FileAccess.file_exists(previous):
			DirAccess.remove_absolute(previous)
		DirAccess.rename_absolute(absolute, previous)
	# Opened once and held: WRITE creates the file, and a handle kept for the session is both
	# faster than an open per flush and immune to the mistake that made the first version write
	# nothing - READ_WRITE does not create a file that is not there, and fails quietly.
	_log_handle = FileAccess.open(LOG_FILE, FileAccess.WRITE)
	# The session's file starts with a header, so a log found later says which run it is.
	_pending.append("=== session %s ===" % Time.get_datetime_string_from_system())
	_log_path = ProjectSettings.globalize_path(LOG_FILE)


func _process(_delta: float) -> void:
	_flush_if_due(false)


## Write what has been collected. Called by the clock during play, by the flush threshold, and once
## more on the way out so the last lines are not lost.
func _flush_if_due(force: bool) -> void:
	if _pending.is_empty():
		return
	var now_ms := Time.get_ticks_msec()
	if not force and now_ms - _last_flush_ms < FLUSH_EVERY_MS and _pending.size() < FLUSH_AT_LINES:
		return
	_last_flush_ms = now_ms
	if _log_handle == null:
		# The log must never take the game down with it.
		_pending.clear()
		return
	for line in _pending:
		_log_handle.store_line(line)
	_log_handle.flush()
	_pending.clear()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_PREDELETE:
		_flush_if_due(true)
		if _log_handle != null:
			_log_handle.close()
			_log_handle = null


## Named [code]log_entry[/code] rather than [code]log[/code] because the global
## scope already owns [code]log()[/code] (natural logarithm).
func log_entry(message: String, category: String = "general", level: Level = Level.INFO) -> void:
	if int(level) < int(min_level):
		return
	var entry := {
		"timestamp": Time.get_time_string_from_system(),
		"level": int(level),
		"level_name": LEVEL_NAMES[int(level)],
		"category": category,
		"message": message,
	}
	var now_ms := Time.get_ticks_msec()
	if message == _last_message and now_ms - _last_at_ms < REPEAT_WINDOW_MS:
		# The same thing, again, too soon. Counted nowhere and written nowhere: a repeat carries no
		# information the last line did not, and the write is the expensive part.
		return
	_last_message = message
	_last_at_ms = now_ms
	_ring.append(entry)
	while _ring.size() > RING_SIZE:
		_ring.pop_front()
	var line := _format(entry)
	_pending.append(line)
	_flush_if_due(false)
	if echo_to_stdout:
		print(line)
	logged.emit(entry)


func debug(message: String, category: String = "general") -> void:
	log_entry(message, category, Level.DEBUG)


func info(message: String, category: String = "general") -> void:
	# The world builder runs on a thread and logs from it; a Node cannot emit signals off the main
	# thread, which produced "The caller thread can't call the function emit_signalp() on this node".
	# Deferring keeps the record and keeps the thread legal.
	if not Thread.is_main_thread():
		call_deferred("info", message, category)
		return
	log_entry(message, category, Level.INFO)


func warn(message: String, category: String = "general") -> void:
	# Same guard as info(): the world builder logs warnings from its thread.
	if not Thread.is_main_thread():
		call_deferred("warn", message, category)
		return
	log_entry(message, category, Level.WARN)


func error(message: String, category: String = "general") -> void:
	log_entry(message, category, Level.ERROR)


func recent(count: int = 50) -> Array[Dictionary]:
	var start: int = maxi(0, _ring.size() - count)
	return _ring.slice(start)


func clear() -> void:
	_ring.clear()


func _format(entry: Dictionary) -> String:
	return "[%s][%s][%s] %s" % [
		entry.get("timestamp", "--:--:--"),
		entry.get("level_name", "INFO"),
		entry.get("category", "general"),
		entry.get("message", ""),
	]
