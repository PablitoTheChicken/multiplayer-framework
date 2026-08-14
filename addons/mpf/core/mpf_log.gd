class_name MpfLog
extends RefCounted
## Channel-aware static logger. Set [member sink] to forward records elsewhere.

enum Level { TRACE, DEBUG, INFO, WARN, ERROR, SILENT }

const LEVEL_NAMES: PackedStringArray = ["TRACE", "DEBUG", "INFO", "WARN", "ERROR", "SILENT"]
const LEVEL_COLORS: PackedStringArray = ["#6b7280", "#38bdf8", "#a3e635", "#fbbf24", "#f87171", "#ffffff"]

static var level: Level = Level.INFO
static var channel_levels: Dictionary = {}
static var rich: bool = true
static var timestamps: bool = false
static var sink: Callable = Callable()


static func set_channel_level(channel: String, value: Level) -> void:
	channel_levels[channel] = value


static func clear_channel_level(channel: String) -> void:
	channel_levels.erase(channel)


static func enabled(channel: String, value: Level) -> bool:
	return value >= (channel_levels.get(channel, level) as Level)


static func trace(channel: String, message: String, data: Dictionary = {}) -> void:
	write(Level.TRACE, channel, message, data)


static func debug(channel: String, message: String, data: Dictionary = {}) -> void:
	write(Level.DEBUG, channel, message, data)


static func info(channel: String, message: String, data: Dictionary = {}) -> void:
	write(Level.INFO, channel, message, data)


static func warn(channel: String, message: String, data: Dictionary = {}) -> void:
	write(Level.WARN, channel, message, data)


static func error(channel: String, message: String, data: Dictionary = {}) -> void:
	write(Level.ERROR, channel, message, data)


static func write(value: Level, channel: String, message: String, data: Dictionary = {}) -> void:
	if not enabled(channel, value):
		return
	if sink.is_valid():
		sink.call(int(value), channel, message, data)
	var line := _format(value, channel, message, data)
	if value == Level.WARN:
		push_warning(line)
	elif value == Level.ERROR:
		push_error(line)
	if rich:
		print_rich("[color=%s]%s[/color]" % [LEVEL_COLORS[int(value)], line])
	else:
		print(line)


static func _format(value: Level, channel: String, message: String, data: Dictionary) -> String:
	var parts := PackedStringArray()
	if timestamps:
		parts.append(Time.get_time_string_from_system())
	parts.append("MPF/%s" % channel)
	parts.append(LEVEL_NAMES[int(value)])
	var head := "[%s]" % " ".join(parts)
	if data.is_empty():
		return "%s %s" % [head, message]
	return "%s %s %s" % [head, message, JSON.stringify(data)]
