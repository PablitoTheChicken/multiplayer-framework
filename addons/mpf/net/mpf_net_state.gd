@tool
class_name MpfNetState
extends Node
## Replicated key/value state for one entity. The authority writes, everyone
## else reads and reacts to [signal changed].
##
## This is the building block for anything that is "a number the server owns
## and clients must agree on": health, ammo, score, door open/closed, capture
## progress. Requires an [MpfNetIdentity] on the same entity.

signal changed(key: StringName, value: Variant, previous: Variant)
signal replicated()

## Send at most every N ticks. Raise it for values that change constantly but
## do not need to be exact, like a stamina bar.
@export var send_every_n_ticks: int = 1
## Warn when a key is read or written without being declared by [method define],
## and when a write changes a value's type. Typos in a StringName are otherwise
## silent, which is the most common way to lose an afternoon with this class.
@export var strict_keys: bool = true

var _values: Dictionary = {}
var _dirty: Dictionary = {}
var _complained: Dictionary = {}
var _identity: MpfNetIdentity = null
var _net: Node = null


func _get_configuration_warnings() -> PackedStringArray:
	if MpfNetIdentity.of(self) == null:
		return ["Needs an MpfNetIdentity on the same entity. Add one as a sibling."]
	return []


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	_identity = MpfNetIdentity.of(self)
	_net = MpfRuntime.net()
	if _identity == null:
		MpfLog.error("net", "MpfNetState needs an MpfNetIdentity on the entity", {"path": String(get_path())})
		return
	if _net != null:
		_net.register_receiver(_identity.net_id, &"__state", _receive)
		# peer_ready, not peer_joined: the entity itself is only sent once the
		# peer has finished loading, and state that arrives before it lands on
		# a peer with nowhere to put it.
		_net.peer_ready.connect(_on_peer_ready)
		_net.register_replicator(self)


func _exit_tree() -> void:
	if Engine.is_editor_hint():
		return
	if _net != null and _identity != null:
		_net.unregister_receiver(_identity.net_id, &"__state")
		_net.unregister_replicator(self)
		if _net.peer_ready.is_connected(_on_peer_ready):
			_net.peer_ready.disconnect(_on_peer_ready)


## Declares a key and its starting value without marking it dirty.
func define(key: StringName, default_value: Variant) -> void:
	if not _values.has(key):
		_values[key] = default_value


func define_many(defaults: Dictionary) -> void:
	for key: Variant in defaults:
		define(StringName(key), defaults[key])


func get_value(key: StringName, default_value: Variant = null) -> Variant:
	if strict_keys and not _values.has(key):
		_complain("read", key)
	return _values.get(key, default_value)


func get_float(key: StringName, default_value: float = 0.0) -> float:
	return float(get_value(key, default_value))


func get_int(key: StringName, default_value: int = 0) -> int:
	return int(get_value(key, default_value))


func get_bool(key: StringName, default_value: bool = false) -> bool:
	return bool(get_value(key, default_value))


func get_string(key: StringName, default_value: String = "") -> String:
	return str(get_value(key, default_value))


func get_vector3(key: StringName, default_value: Vector3 = Vector3.ZERO) -> Vector3:
	var value: Variant = get_value(key, default_value)
	return value if typeof(value) == TYPE_VECTOR3 else default_value


## Keys declared with [method define], for debug overlays and tests.
func keys() -> Array:
	return _values.keys()


func has(key: StringName) -> bool:
	return _values.has(key)


func all() -> Dictionary:
	return _values.duplicate(true)


## Authority only. Applies locally and queues the change for replication.
func set_value(key: StringName, value: Variant) -> void:
	if not is_authority():
		MpfLog.warn("net", "Ignored non-authoritative state write", {"key": String(key)})
		return
	if strict_keys:
		if not _values.has(key):
			_complain("write", key)
		elif _values[key] != null and value != null and typeof(_values[key]) != typeof(value):
			MpfLog.warn("net", "State key changed type", {
				"key": String(key),
				"was": type_string(typeof(_values[key])),
				"now": type_string(typeof(value)),
			})
	if _apply(key, value):
		_dirty[key] = value


func set_values(values: Dictionary) -> void:
	for key: Variant in values:
		set_value(StringName(key), values[key])


## Authority only. Adds to a numeric value and returns the result.
func add(key: StringName, delta: float) -> float:
	var result := float(get_value(key, 0.0)) + delta
	set_value(key, result)
	return result


func is_authority() -> bool:
	return _identity == null or _identity.is_authority()


## Sends the full state, for a late joiner or after a scene change.
## Pass 0 to send to everyone.
func force_sync(peer_id: int = 0) -> void:
	if not is_authority() or _net == null or _identity == null or _values.is_empty():
		return
	# A client cannot address another client, so an owner-authoritative entity
	# must send up and let the server relay.
	if not MpfRuntime.is_server():
		_net.send_to_server(&"__state", {_identity.net_id: _values.duplicate(true)})
	elif peer_id == 0:
		_net.send_to_all(&"__state", {_identity.net_id: _values.duplicate(true)}, [_net.local_id()])
	else:
		_net.queue_update_to(peer_id, &"__state", _identity.net_id, _values.duplicate(true))


## A peer that joins after a value changed would otherwise keep the default it
## seeded with [method define] forever, so the authority resends everything.
func _on_peer_ready(peer: MpfPeer) -> void:
	if peer.id != _net.local_id():
		force_sync(peer.id)


func _complain(action: String, key: StringName) -> void:
	# Once per key: this fires from reads that can happen every frame, and a
	# warning per frame buries the very message it is trying to deliver.
	if _complained.has(key):
		return
	_complained[key] = true
	MpfLog.warn("net", "Undeclared state key", {
		"action": action,
		"key": String(key),
		"declared": _values.keys(),
		"entity": String(get_path()) if is_inside_tree() else "",
	})


func _apply(key: StringName, value: Variant) -> bool:
	var previous: Variant = _values.get(key)
	if _values.has(key) and previous == value:
		return false
	_values[key] = value
	changed.emit(key, value, previous)
	return true


## Driven by Net's shared replication loop rather than a per-node signal.
func _mpf_replicate(index: int) -> void:
	if _dirty.is_empty() or _net == null or _identity == null:
		return
	if send_every_n_ticks > 1 and index % send_every_n_ticks != 0:
		return
	_net.queue_update(&"__state", _identity.net_id, _dirty.duplicate())
	_dirty.clear()


func _receive(sender: int, data: Variant) -> bool:
	if typeof(data) != TYPE_DICTIONARY or not _sender_allowed(sender):
		return false
	for key: Variant in data as Dictionary:
		_apply(StringName(key), (data as Dictionary)[key])
	replicated.emit()
	return true


## The server accepts writes only from the owner of an owner-authoritative
## entity. Clients accept writes only from the server.
func _sender_allowed(sender: int) -> bool:
	if _identity == null:
		return false
	if MpfRuntime.is_server():
		return _identity.authority == MpfNetIdentity.Authority.OWNER and sender == _identity.owner_peer_id
	return sender == 1
