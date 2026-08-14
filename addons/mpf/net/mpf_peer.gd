class_name MpfPeer
extends RefCounted
## One connected machine. The server owns the roster and replicates it, so
## these values are identical on every peer.

## Multiplayer id. 1 is always the server.
var id: int = 0
var display_name: String = "Player"
## Platform account id as text; Steam ids exceed JSON's safe integer range.
var platform_id: String = ""
var is_local: bool = false
var is_server: bool = false
## False until the handshake completes.
var authenticated: bool = false
## True when this peer reclaimed a slot held open after a earlier disconnect.
var resumed: bool = false
## False until the peer confirms it finished loading the server's scene.
## Spawn entities on [code]Net.peer_ready[/code], not [code]peer_joined[/code].
var scene_ready: bool = false
var joined_at_ms: int = 0
## Server-side stamp of the last message received from this peer. Drives the
## heartbeat timeout, which notices a dropped player long before ENet does.
var last_seen_ms: int = 0
var rtt_ms: float = 0.0
## Replicated game data: team, character, ready state, cosmetics.
var meta: Dictionary = {}


func connected_for() -> float:
	return float(Time.get_ticks_msec() - joined_at_ms) * 0.001


func get_meta_value(key: StringName, default: Variant = null) -> Variant:
	return meta.get(key, default)


func to_dict() -> Dictionary:
	return {"id": id, "name": display_name, "pid": platform_id, "meta": meta}


static func from_dict(data: Dictionary) -> MpfPeer:
	var peer := MpfPeer.new()
	peer.id = int(data.get("id", 0))
	peer.display_name = String(data.get("name", "Player"))
	peer.platform_id = String(data.get("pid", ""))
	peer.meta = data.get("meta", {}) as Dictionary
	peer.is_server = peer.id == 1
	peer.joined_at_ms = Time.get_ticks_msec()
	return peer


## Where this peer's save data is filed, and what a held reconnect slot is
## keyed by. Assigned by the server during the handshake - never by the peer.
var storage_key: String = ""


## Resolves a storage key from the strongest identity available.
##
## A display name must never be used on its own: it is chosen by the client, so
## keying saves on it lets anyone load anyone else's progression by picking
## their name. The token is a secret the server issued to that player earlier,
## which makes it unguessable rather than merely unlikely.
static func storage_key_for(platform_id: String, token: String, display_name: String) -> String:
	if platform_id != "":
		return "steam:%s" % platform_id
	if token != "":
		return "tok:%s" % token
	# Last resort for a peer with no verified identity and no token yet.
	return "guest:%s" % display_name.to_lower().validate_filename()


func _to_string() -> String:
	return "MpfPeer(%d, %s)" % [id, display_name]
