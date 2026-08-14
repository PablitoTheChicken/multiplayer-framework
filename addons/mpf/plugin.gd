@tool
extends EditorPlugin
## Registers the MPF autoloads and project settings.

const AUTOLOADS: Array[Array] = [
	["MPF", "res://addons/mpf/runtime/mpf_root.gd"],
	["Net", "res://addons/mpf/runtime/mpf_net.gd"],
	["Save", "res://addons/mpf/runtime/mpf_save.gd"],
]

const SETTINGS: Array[Dictionary] = [
	{"name": "mpf/logging/level", "value": 2, "type": TYPE_INT, "hint": PROPERTY_HINT_ENUM, "hint_string": "Trace,Debug,Info,Warn,Error,Silent"},
	{"name": "mpf/logging/rich_output", "value": true, "type": TYPE_BOOL},
	{"name": "mpf/logging/timestamps", "value": false, "type": TYPE_BOOL},
	{"name": "mpf/network/tick_rate", "value": 30, "type": TYPE_INT, "hint": PROPERTY_HINT_RANGE, "hint_string": "5,120,1"},
	{"name": "mpf/network/cli_dedicated", "value": true, "type": TYPE_BOOL},
	# Default 0, not a real id: Godot omits a setting that equals its initial
	# value, so defaulting to 480 meant setting it to 480 never persisted and
	# exported builds read nothing.
	{"name": "mpf/network/steam_app_id", "value": 0, "type": TYPE_INT},
	{"name": "mpf/network/experimental_steam", "value": false, "type": TYPE_BOOL},
	{"name": "mpf/save/backend", "value": "auto", "type": TYPE_STRING, "hint": PROPERTY_HINT_ENUM, "hint_string": "auto,local,steam_cloud"},
	{"name": "mpf/save/directory", "value": "user://saves", "type": TYPE_STRING},
	{"name": "mpf/save/format", "value": "json", "type": TYPE_STRING, "hint": PROPERTY_HINT_ENUM, "hint_string": "json,binary"},
	{"name": "mpf/save/version", "value": 1, "type": TYPE_INT},
]


func _enter_tree() -> void:
	_define_settings()
	for entry: Array in AUTOLOADS:
		add_autoload_singleton(entry[0], entry[1])


func _exit_tree() -> void:
	for entry: Array in AUTOLOADS:
		remove_autoload_singleton(entry[0])


func _define_settings() -> void:
	var added := false
	for setting: Dictionary in SETTINGS:
		var key := String(setting["name"])
		if not ProjectSettings.has_setting(key):
			ProjectSettings.set_setting(key, setting["value"])
			added = true
		ProjectSettings.set_initial_value(key, setting["value"])
		ProjectSettings.add_property_info({
			"name": key,
			"type": setting["type"],
			"hint": setting.get("hint", PROPERTY_HINT_NONE),
			"hint_string": setting.get("hint_string", ""),
		})
	if added:
		ProjectSettings.save()
