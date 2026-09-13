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
var echo_to_stdout: bool = true

var _ring: Array[Dictionary] = []


func _ready() -> void:
	# Logging must keep working while gameplay is paused.
	process_mode = Node.PROCESS_MODE_ALWAYS


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
	_ring.append(entry)
	while _ring.size() > RING_SIZE:
		_ring.pop_front()
	if echo_to_stdout:
		print(_format(entry))
	logged.emit(entry)


func debug(message: String, category: String = "general") -> void:
	log_entry(message, category, Level.DEBUG)


func info(message: String, category: String = "general") -> void:
	log_entry(message, category, Level.INFO)


func warn(message: String, category: String = "general") -> void:
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
