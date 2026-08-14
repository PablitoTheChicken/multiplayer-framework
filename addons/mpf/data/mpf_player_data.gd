class_name MpfPlayerData
extends RefCounted
## Persistent per-player data for one connected peer, owned by the server.
##
## Each field declares how far it travels: private stays on the server, owner
## reaches only that player, public reaches everyone. Clients receive a
## read-only view.

signal changed(key: StringName, value: Variant, previous: Variant)

enum Scope {
	PRIVATE, ## Server only. Anti-cheat state, ban notes, raw currency ledgers.
	OWNER, ## Replicated to the owning client. Inventory, quest progress.
	PUBLIC, ## Replicated to everyone. Level, cosmetics, scoreboard stats.
}

var peer_id: int = 0
## Storage key this data is filed under, usually a platform account id.
var storage_key: String = ""
var loaded: bool = false

var _values: Dictionary = {}


func get_value(key: StringName, default_value: Variant = null) -> Variant:
	return _values.get(key, default_value)


func has(key: StringName) -> bool:
	return _values.has(key)


func all() -> Dictionary:
	return _values.duplicate(true)


## Writes a value. Only meaningful on the server; clients receive replicated
## updates through [method apply_replicated].
func set_value(key: StringName, value: Variant) -> bool:
	var previous: Variant = _values.get(key)
	if _values.has(key) and previous == value:
		return false
	_values[key] = value
	changed.emit(key, value, previous)
	return true


func add(key: StringName, delta: float) -> float:
	var result := float(get_value(key, 0.0)) + delta
	set_value(key, result)
	return result


func apply_replicated(values: Dictionary) -> void:
	for key: Variant in values:
		set_value(StringName(key), values[key])
	loaded = true


## The subset of fields visible at [param scope] or wider.
func slice(fields: Dictionary, scope: Scope) -> Dictionary:
	var out := {}
	for key: Variant in fields:
		if int((fields[key] as Dictionary).get("scope", Scope.PRIVATE)) >= int(scope) and _values.has(key):
			out[key] = _values[key]
	return out


func to_dict() -> Dictionary:
	return _values.duplicate(true)


func _to_string() -> String:
	return "MpfPlayerData(peer %d, %s)" % [peer_id, storage_key]
