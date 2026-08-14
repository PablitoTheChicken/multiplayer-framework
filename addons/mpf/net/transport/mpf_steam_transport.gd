class_name MpfSteamTransport
extends MpfTransport
## Steam peer-to-peer transport. Connections are addressed by Steam id and
## routed through Valve's relay, so no port forwarding is involved.

var virtual_port: int = 0


func id() -> StringName:
	return &"steam"


func is_available() -> bool:
	return MpfSteam.is_available() and MpfSteam.has_peer_class()


func supports_lobbies() -> bool:
	return true


func create_server(options: Dictionary) -> MultiplayerPeer:
	if not _ensure_ready(options):
		return null
	var peer := MpfSteam.make_peer()
	if peer == null:
		_fail("could not instantiate a Steam multiplayer peer")
		return null
	virtual_port = int(options.get("virtual_port", 0))
	var result: Variant = MpfSteam.invoke_on(peer, ["create_host", "createHost"], [virtual_port, []], null)
	if not _ok(result):
		_fail("create_host failed (%s)" % str(result))
		return null
	MpfLog.info("net", "Steam host listening", {"steam_id": MpfSteam.steam_id()})
	return peer


func create_client(target: Variant, options: Dictionary) -> MultiplayerPeer:
	if not _ensure_ready(options):
		return null
	var host_id := _steam_id_of(target)
	if host_id == 0:
		_fail("no Steam id to connect to")
		return null
	var peer := MpfSteam.make_peer()
	if peer == null:
		_fail("could not instantiate a Steam multiplayer peer")
		return null
	virtual_port = int(options.get("virtual_port", 0))
	var result: Variant = MpfSteam.invoke_on(peer, ["create_client", "createClient"], [host_id, virtual_port, []], null)
	if not _ok(result):
		_fail("create_client failed (%s)" % str(result))
		return null
	MpfLog.info("net", "Steam client connecting", {"host": host_id})
	return peer


func poll(_delta: float) -> void:
	MpfSteam.run_callbacks()


func describe(target: Variant) -> String:
	return "steam://%d" % _steam_id_of(target)


func _ensure_ready(options: Dictionary) -> bool:
	if not MpfSteam.is_available():
		_fail("GodotSteam is not installed")
		return false
	if not MpfSteam.has_peer_class():
		_fail("no SteamMultiplayerPeer class is registered")
		return false
	if not MpfSteam.initialized and not MpfSteam.initialize(int(options.get("app_id", 0))):
		_fail("Steam failed to initialise")
		return false
	return true


static func _steam_id_of(target: Variant) -> int:
	if target is MpfLobby:
		return int((target as MpfLobby).owner_id)
	match typeof(target):
		TYPE_INT:
			return int(target)
		TYPE_STRING, TYPE_STRING_NAME:
			var text := String(target).trim_prefix("steam://")
			return int(text) if text.is_valid_int() else 0
		TYPE_DICTIONARY:
			return int((target as Dictionary).get("steam_id", 0))
	return 0


## GodotSteam variants return OK, true, or nothing at all on success.
static func _ok(result: Variant) -> bool:
	match typeof(result):
		TYPE_NIL:
			return true
		TYPE_BOOL:
			return bool(result)
		TYPE_INT:
			return int(result) == OK
		_:
			return true
