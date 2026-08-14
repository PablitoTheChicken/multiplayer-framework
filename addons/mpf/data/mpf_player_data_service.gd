class_name MpfPlayerDataService
extends Node
## Loads each connected player's persistent data on the server, replicates the
## parts they are allowed to see, and writes it back when they leave.
##
## This is the piece that makes persistent progression work in multiplayer:
## the server is the only writer, so a client cannot grant itself levels or
## currency by editing a local file.

signal player_loaded(peer_id: int, data: MpfPlayerData)
signal player_saved(peer_id: int)

## `func(peer: MpfPeer) -> String` deciding the storage key. Defaults to the
## platform id, falling back to a name-derived key for non-Steam sessions.
var key_provider: Callable = Callable()
## Seconds between background writes. 0 disables autosave.
var autosave_interval: float = 60.0
var enabled: bool = true

var _fields: Dictionary = {}
var _players: Dictionary = {}
var _timer: float = 0.0
var _save: Node = null
var _net: Node = null


func _ready() -> void:
	_save = get_parent()
	_net = MpfRuntime.net()
	if _net == null:
		return
	_net.peer_joined.connect(_on_peer_joined)
	_net.peer_left.connect(_on_peer_left)
	_net.register_channel(&"__pd", _receive, {
		"internal": true, "direction": "to_clients", "max_bytes": 16384,
	})


func _process(delta: float) -> void:
	if not enabled or autosave_interval <= 0.0 or not MpfRuntime.is_server():
		return
	_timer += delta
	if _timer < autosave_interval:
		return
	_timer = 0.0
	save_all()


## Declares a persisted field, its default, and how far it replicates.
func register_field(key: StringName, default_value: Variant, scope: MpfPlayerData.Scope = MpfPlayerData.Scope.PRIVATE) -> void:
	_fields[key] = {"default": default_value, "scope": int(scope)}


func fields() -> Dictionary:
	return _fields.duplicate(true)


## The data for one peer, created empty if it has not loaded yet.
func get_for(peer_id: int) -> MpfPlayerData:
	var found: MpfPlayerData = _players.get(peer_id)
	if found == null:
		found = MpfPlayerData.new()
		found.peer_id = peer_id
		_players[peer_id] = found
	return found


func local() -> MpfPlayerData:
	return get_for(MpfRuntime.local_id())


func all() -> Array[MpfPlayerData]:
	var out: Array[MpfPlayerData] = []
	for data: MpfPlayerData in _players.values():
		out.append(data)
	return out


## Server only. Writes one player's data back to storage.
func save_for(peer_id: int) -> void:
	if not MpfRuntime.is_server() or _save == null:
		return
	var data: MpfPlayerData = _players.get(peer_id)
	if data == null or not data.loaded or data.storage_key == "":
		return
	var profile: MpfProfile = _save.open(_profile_id(data.storage_key))
	for key: Variant in _fields:
		profile.set_value(String(key), data.get_value(StringName(key)))
	if profile.save() == OK:
		player_saved.emit(peer_id)


func save_all() -> void:
	for peer_id: int in _players.keys():
		save_for(peer_id)


## Server only. Pushes the current values to whoever is allowed to see them.
func replicate(peer_id: int) -> void:
	if not MpfRuntime.is_server() or _net == null:
		return
	var data: MpfPlayerData = _players.get(peer_id)
	if data == null:
		return
	var public := data.slice(_fields, MpfPlayerData.Scope.PUBLIC)
	if not public.is_empty():
		_net.send_to_all(&"__pd", {"id": peer_id, "v": public}, [_net.local_id()])
	var owner_only := data.slice(_fields, MpfPlayerData.Scope.OWNER)
	if not owner_only.is_empty() and peer_id != _net.local_id():
		_net.send_to(&"__pd", peer_id, {"id": peer_id, "v": owner_only})


func _on_peer_joined(peer: MpfPeer) -> void:
	if not MpfRuntime.is_server() or _save == null:
		return
	var data := get_for(peer.id)
	data.storage_key = _key_for(peer)
	var profile: MpfProfile = _save.open(_profile_id(data.storage_key))
	for key: Variant in _fields:
		data.set_value(StringName(key), profile.get_value(String(key), (_fields[key] as Dictionary)["default"]))
	data.loaded = true
	MpfLog.info("save", "Player data loaded", {"peer": peer.id, "key": data.storage_key})
	replicate(peer.id)
	player_loaded.emit(peer.id, data)
	# Existing players' public data is not automatically known to a joiner.
	for other_id: int in _players.keys():
		if other_id != peer.id:
			replicate(other_id)


func _on_peer_left(peer: MpfPeer, _reason: String) -> void:
	if MpfRuntime.is_server():
		save_for(peer.id)
	_players.erase(peer.id)


func _receive(_sender: int, payload: Dictionary) -> void:
	if MpfRuntime.is_server():
		return
	var target := get_for(int(payload.get("id", 0)))
	target.apply_replicated(payload.get("v", {}) as Dictionary)


func _key_for(peer: MpfPeer) -> String:
	if key_provider.is_valid():
		return String(key_provider.call(peer))
	if peer.platform_id != "":
		return peer.platform_id
	return "local_%s" % peer.display_name.to_lower().validate_filename()


static func _profile_id(storage_key: String) -> String:
	return "player_%s" % storage_key
