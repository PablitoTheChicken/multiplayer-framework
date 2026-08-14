extends Node
## MPF autoload. Owns the event bus, the fixed tick clock and framework config.
## Registered by the plugin; do not add it manually.

signal booted()

const VERSION := "1.0.0"

var events: MpfEvents
var tick: MpfTick

var net: Node:
	get:
		return MpfRuntime.net()

var save: Node:
	get:
		return MpfRuntime.save()


func _init() -> void:
	events = MpfEvents.new()


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	tick = MpfTick.new()
	tick.name = "Tick"
	add_child(tick)
	apply_project_settings()
	MpfLog.info("core", "MPF ready", {"version": VERSION, "tick_rate": tick.rate})
	booted.emit()


func apply_project_settings() -> void:
	MpfLog.level = int(ProjectSettings.get_setting("mpf/logging/level", MpfLog.Level.INFO)) as MpfLog.Level
	MpfLog.rich = bool(ProjectSettings.get_setting("mpf/logging/rich_output", true))
	MpfLog.timestamps = bool(ProjectSettings.get_setting("mpf/logging/timestamps", false))
	tick.rate = int(ProjectSettings.get_setting("mpf/network/tick_rate", 30))


func setting(key: String, default: Variant = null) -> Variant:
	return ProjectSettings.get_setting("mpf/%s" % key, default)
