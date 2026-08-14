class_name MpfLobby
extends RefCounted
## A joinable session advertised by Steam or by LAN broadcast.

## &"steam" or &"lan".
var source: StringName = &"lan"
var id: String = ""
var name: String = "Lobby"
var host_name: String = ""
## Steam id of the lobby owner, used as the connection target.
var owner_id: String = ""
## Direct address for LAN lobbies.
var address: String = ""
var port: int = 0
var player_count: int = 0
var max_players: int = 0
var has_password: bool = false
var game_version: String = ""
var data: Dictionary = {}


func is_full() -> bool:
	return max_players > 0 and player_count >= max_players


## The value to hand to [code]Net.join()[/code].
func connect_target() -> Variant:
	if source == &"steam":
		return owner_id
	return "%s:%d" % [address, port]


func to_dict() -> Dictionary:
	return {
		"source": String(source),
		"id": id,
		"name": name,
		"host": host_name,
		"owner": owner_id,
		"address": address,
		"port": port,
		"players": player_count,
		"max": max_players,
		"pw": has_password,
		"ver": game_version,
		"data": data,
	}


static func from_dict(raw: Dictionary) -> MpfLobby:
	var lobby := MpfLobby.new()
	lobby.source = StringName(raw.get("source", "lan"))
	lobby.id = String(raw.get("id", ""))
	lobby.name = String(raw.get("name", "Lobby"))
	lobby.host_name = String(raw.get("host", ""))
	lobby.owner_id = String(raw.get("owner", ""))
	lobby.address = String(raw.get("address", ""))
	lobby.port = int(raw.get("port", 0))
	lobby.player_count = int(raw.get("players", 0))
	lobby.max_players = int(raw.get("max", 0))
	lobby.has_password = bool(raw.get("pw", false))
	lobby.game_version = String(raw.get("ver", ""))
	lobby.data = raw.get("data", {}) as Dictionary
	return lobby


func _to_string() -> String:
	return "MpfLobby(%s %s %d/%d)" % [source, name, player_count, max_players]
