class_name MpfSteamTransport
extends MpfTransport
## Steam peer-to-peer transport. Peers are addressed by Steam id and routed
## through Valve's relay, so there is no port forwarding and no exposed IP.
##
## Written against the real SteamMultiplayerPeer surface:
##   create_host(virtual_port := 0) -> int
##   create_client(steam_id: int, virtual_port := 0) -> int
##   get_peer(peer_id: int) -> Object
##   properties: server_relay, no_nagle, no_delay, debug_level

## Steam's own virtual port. Only matters if you run several logical services
## over one Steam identity; leave it at 0.
@export var virtual_port: int = 0
## Route through Valve's relay rather than attempting direct connections.
## Hides player IPs and works behind strict NATs, at a small latency cost.
var use_relay: bool = true
## Disable Nagle batching. Lower latency, more packets.
var no_nagle: bool = false

var _peer: MultiplayerPeer = null


func id() -> StringName:
	return &"steam"


## Off unless explicitly enabled. This transport has not been verified against
## a live Steam session, so it must never be selected by accident - falling
## back to ENet is far better than shipping an unproven path.
static func enabled() -> bool:
	return bool(ProjectSettings.get_setting("mpf/network/experimental_steam", false))


func is_available() -> bool:
	if not enabled():
		return false
	return MpfSteam.is_available() and MpfSteam.has_peer_class()


func supports_lobbies() -> bool:
	return true


func create_server(options: Dictionary) -> MultiplayerPeer:
	if not _ensure_ready(options):
		return null
	var peer := _make_configured_peer()
	if peer == null:
		return null
	var result: Variant = MpfSteam.invoke_on(peer, ["create_host", "createHost"], [virtual_port], FAILED)
	if not _ok(result):
		_fail("create_host failed (%s)" % _describe_error(result))
		return null
	_peer = peer
	MpfLog.info("net", "Steam host listening", {"steam_id": MpfSteam.steam_id(), "relay": use_relay})
	return peer


func create_client(target: Variant, options: Dictionary) -> MultiplayerPeer:
	if not _ensure_ready(options):
		return null
	var host_id := _steam_id_of(target)
	if host_id == 0:
		_fail("no Steam id to connect to")
		return null
	var peer := _make_configured_peer()
	if peer == null:
		return null
	var result: Variant = MpfSteam.invoke_on(peer, ["create_client", "createClient"], [host_id, virtual_port], FAILED)
	if not _ok(result):
		_fail("create_client failed (%s)" % _describe_error(result))
		return null
	_peer = peer
	MpfLog.info("net", "Steam client connecting", {"host": host_id})
	return peer


func poll(_delta: float) -> void:
	MpfSteam.run_callbacks()


func shutdown() -> void:
	_peer = null


func describe(target: Variant) -> String:
	return "steam://%d" % _steam_id_of(target)


## The Steam id behind a multiplayer peer id, or 0 when it cannot be
## established. This is what makes a claimed identity checkable: the transport
## knows who a peer actually is, the peer's own word for it proves nothing.
func peer_steam_id(peer_id: int) -> int:
	if _peer == null or not _peer.has_method("get_peer"):
		return 0
	var entry: Variant = _peer.call("get_peer", peer_id)
	if entry == null or not (entry is Object):
		return 0
	var handle := entry as Object
	for getter: String in ["get_steam_id", "getSteamID"]:
		if handle.has_method(getter):
			return int(handle.call(getter))
	for property: String in ["steam_id", "steamId"]:
		var value: Variant = handle.get(property)
		if value != null and typeof(value) == TYPE_INT:
			return int(value)
	return 0


func _make_configured_peer() -> MultiplayerPeer:
	var peer := MpfSteam.make_peer()
	if peer == null:
		_fail("could not instantiate a Steam multiplayer peer")
		return null
	# These exist on SteamMultiplayerPeer but not on every alternative, so set
	# them only where present rather than assuming the shape.
	for entry: Array in [["server_relay", use_relay], ["no_nagle", no_nagle]]:
		if String(entry[0]) in peer:
			peer.set(String(entry[0]), entry[1])
	return peer


func _ensure_ready(options: Dictionary) -> bool:
	if not enabled():
		_fail("the Steam transport is experimental; enable mpf/network/experimental_steam to use it")
		return false
	if not MpfSteam.is_available():
		_fail("GodotSteam is not installed")
		return false
	if not MpfSteam.has_peer_class():
		_fail("no SteamMultiplayerPeer class is registered")
		return false
	if not MpfSteam.initialized and not MpfSteam.initialize(int(options.get("app_id", 0))):
		# Report Steam's own diagnosis. Guessing at the cause sent a previous
		# session hunting a missing steam_appid.txt when the real problem was
		# an out-of-date Steam client.
		_fail("Steam failed to initialise: %s" % MpfSteam.last_init_error())
		return false
	if not MpfSteam.is_running():
		MpfLog.warn("net", "Steam reports it is not running; connections will likely fail")
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


## create_host and create_client return an Error, but older builds returned
## nothing at all, so treat only an explicit failure as failure.
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


static func _describe_error(result: Variant) -> String:
	if typeof(result) == TYPE_INT:
		return error_string(int(result))
	return str(result)
