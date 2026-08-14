class_name MpfProfile
extends RefCounted
## One save slot. Values live in a nested dictionary addressed by
## slash-separated paths, so related data groups naturally without you
## declaring a schema up front.
##
## Obtained from [code]Save.open()[/code], never constructed directly.

signal changed(path: String, value: Variant, previous: Variant)
signal saved()

var id: String = "default"
var version: int = 0
## Unix timestamp of the last successful write.
var saved_at: int = 0
## True when there are unwritten changes.
var dirty: bool = false

var _data: Dictionary = {}
var _service: Node = null


func attach(service: Node) -> void:
	_service = service


func get_value(path: String, default_value: Variant = null) -> Variant:
	return MpfUtil.dig(_data, path, default_value)


func set_value(path: String, value: Variant) -> bool:
	var previous: Variant = MpfUtil.dig(_data, path)
	if not MpfUtil.bury(_data, path, value):
		return false
	dirty = true
	changed.emit(path, value, previous)
	return true


func add(path: String, delta: float) -> float:
	var result := float(get_value(path, 0.0)) + delta
	set_value(path, result)
	return result


func has(path: String) -> bool:
	return MpfUtil.dig(_data, path, null) != null


func erase(path: String) -> bool:
	var parts := path.split("/", false)
	if parts.is_empty():
		return false
	var cursor: Variant = _data
	for i: int in parts.size() - 1:
		if typeof(cursor) != TYPE_DICTIONARY:
			return false
		cursor = (cursor as Dictionary).get(parts[i])
	if typeof(cursor) != TYPE_DICTIONARY:
		return false
	var removed := (cursor as Dictionary).erase(parts[parts.size() - 1])
	dirty = dirty or removed
	return removed


func merge(values: Dictionary) -> void:
	_data = MpfUtil.deep_merge(_data, values)
	dirty = true


## Replaces every value. Used by the loader; also handy for "reset progress".
func replace(values: Dictionary) -> void:
	_data = values.duplicate(true)
	dirty = true


func data() -> Dictionary:
	return _data.duplicate(true)


func is_empty() -> bool:
	return _data.is_empty()


## Writes to disk now. Returns [constant OK] on success.
func save() -> Error:
	if _service == null:
		return ERR_UNCONFIGURED
	var result: Error = _service.write(self)
	if result == OK:
		saved.emit()
	return result


## Marks the profile for the next autosave instead of writing immediately.
func queue_save() -> void:
	dirty = true


## Discards unsaved changes and re-reads from the backend.
func reload() -> Error:
	if _service == null:
		return ERR_UNCONFIGURED
	return _service.read_into(self)


func _to_string() -> String:
	return "MpfProfile(%s, v%d)" % [id, version]
