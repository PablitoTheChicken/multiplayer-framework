class_name MpfLobbyService
extends Node
## Advertising, discovery and joining. Uses Steam lobbies when GodotSteam is
## present and falls back to LAN broadcast otherwise, behind one API.

signal advertised(lobby: MpfLobby)
signal resolved(lobby_id: String, target: Variant)
signal failed(reason: String)
signal list_updated(lobbies: Array[MpfLobby])
signal invite_accepted(target: Variant)

var use_steam: bool = false
var beacon: MpfLanBeacon = null

var _steam_lobby: int = 0
var _steam_lobbies: Array[MpfLobby] = []
var _hosted: MpfLobby = null
var _joining: MpfLobby = null


func _ready() -> void:
	beacon = MpfLanBeacon.new()
	beacon.name = "LanBeacon"
	add_child(beacon)
	beacon.list_changed.connect(_on_lan_list_changed)
	_bind_steam()
	# Accepting an invite from outside the game launches us with the lobby id
	# on the command line; surface it the same way an in-game invite arrives.
	var launched := MpfSteam.launch_lobby_id()
	if launched != 0:
		var lobby := MpfLobby.new()
		lobby.source = &"steam"
		lobby.id = str(launched)
		invite_accepted.emit.call_deferred(lobby)


## Publishes [param lobby] so other players can find it.
func advertise(lobby: MpfLobby, steam: bool) -> void:
	_hosted = lobby
	use_steam = steam
	if steam and MpfSteam.is_available():
		lobby.source = &"steam"
		MpfSteam.create_lobby(_visibility_code(lobby.data.get("visibility", "public")), maxi(2, lobby.max_players))
		return
	lobby.source = &"lan"
	beacon.advertise(lobby)
	advertised.emit(lobby)


## Refreshes the advertised player count without restarting the broadcast.
func update_advertisement(player_count: int) -> void:
	if _hosted == null:
		return
	_hosted.player_count = player_count
	if _hosted.source == &"steam" and _steam_lobby != 0:
		MpfSteam.set_lobby_data(_steam_lobby, "players", str(player_count))
	else:
		beacon.update_advertisement(_hosted)


func stop_advertising() -> void:
	beacon.stop()
	if _steam_lobby != 0:
		MpfSteam.leave_lobby(_steam_lobby)
		MpfSteam.clear_rich_presence()
		_steam_lobby = 0
	_hosted = null


## Steam ids of everyone in the current lobby, owner first.
func lobby_members() -> PackedInt64Array:
	return MpfSteam.lobby_members(_steam_lobby) if _steam_lobby != 0 else PackedInt64Array()


## The lobby this process was launched to join, when a player accepted an
## invite while the game was closed. Zero when there was none.
func pending_launch_lobby() -> int:
	return MpfSteam.launch_lobby_id()


## Starts a lobby search. Results arrive on [signal list_updated].
func refresh(steam: bool) -> void:
	use_steam = steam
	if steam and MpfSteam.is_available():
		_steam_lobbies.clear()
		MpfSteam.limit_lobby_results(50)
		MpfSteam.request_lobby_list()
		return
	beacon.clear()
	beacon.listen()


func stop_refresh() -> void:
	if beacon.mode == MpfLanBeacon.Mode.LISTENING:
		beacon.stop()


## Resolves [param lobby] to something [code]Net.join()[/code] can connect to.
## LAN lobbies resolve immediately; Steam lobbies resolve after the lobby is
## actually joined and the owner is known.
func resolve(lobby: MpfLobby) -> void:
	_joining = lobby
	if lobby.source == &"steam":
		if not MpfSteam.is_available():
			failed.emit("Steam is not available")
			return
		MpfSteam.join_lobby(int(lobby.id))
		return
	resolved.emit(lobby.id, lobby.connect_target())


func leave() -> void:
	stop_advertising()
	stop_refresh()
	_joining = null


## Opens the Steam overlay invite dialog for the current lobby.
func invite() -> bool:
	if _steam_lobby == 0:
		return false
	MpfSteam.open_invite_overlay(_steam_lobby)
	return true


func current_lobby_id() -> String:
	if _steam_lobby != 0:
		return str(_steam_lobby)
	return _hosted.id if _hosted != null else ""


func lobbies() -> Array[MpfLobby]:
	return _steam_lobbies if use_steam else beacon.lobbies()


func _bind_steam() -> void:
	if not MpfSteam.is_available():
		return
	MpfSteam.listen("lobby_created", _on_steam_lobby_created)
	MpfSteam.listen("lobby_joined", _on_steam_lobby_joined)
	MpfSteam.listen("lobby_match_list", _on_steam_match_list)
	MpfSteam.listen("join_requested", _on_steam_join_requested)


func _on_steam_lobby_created(result: int, lobby_id: int) -> void:
	if result != 1 or _hosted == null:
		failed.emit("Steam lobby creation failed (%d)" % result)
		return
	_steam_lobby = lobby_id
	_hosted.id = str(lobby_id)
	_hosted.owner_id = str(MpfSteam.steam_id())
	MpfSteam.set_lobby_data(lobby_id, "name", _hosted.name)
	MpfSteam.set_lobby_data(lobby_id, "host", _hosted.host_name)
	MpfSteam.set_lobby_data(lobby_id, "owner", _hosted.owner_id)
	MpfSteam.set_lobby_data(lobby_id, "version", _hosted.game_version)
	MpfSteam.set_lobby_data(lobby_id, "max", str(_hosted.max_players))
	MpfSteam.set_lobby_data(lobby_id, "players", str(_hosted.player_count))
	MpfSteam.set_lobby_data(lobby_id, "pw", "1" if _hosted.has_password else "0")
	MpfSteam.set_lobby_data(lobby_id, "mpf", "1")
	MpfSteam.set_lobby_joinable(lobby_id, true)
	# Rich presence is what makes "Join game" appear in a friend's Steam list;
	# without it invites are the only way in.
	MpfSteam.set_rich_presence("connect", "+connect_lobby %d" % lobby_id)
	MpfSteam.set_rich_presence("steam_player_group", str(lobby_id))
	advertised.emit(_hosted)


func _on_steam_lobby_joined(lobby_id: int, _permissions: int, _locked: bool, response: int) -> void:
	if response != 1:
		failed.emit("could not join Steam lobby (%d)" % response)
		return
	var owner := MpfSteam.lobby_owner(lobby_id)
	if owner == MpfSteam.steam_id():
		return # We own it; hosting handles this path.
	_steam_lobby = lobby_id
	resolved.emit(str(lobby_id), str(owner))


func _on_steam_match_list(lobby_ids: Array) -> void:
	_steam_lobbies.clear()
	for raw_id: Variant in lobby_ids:
		var lobby_id := int(raw_id)
		if MpfSteam.get_lobby_data(lobby_id, "mpf") != "1":
			continue
		var lobby := MpfLobby.new()
		lobby.source = &"steam"
		lobby.id = str(lobby_id)
		lobby.name = MpfSteam.get_lobby_data(lobby_id, "name")
		lobby.host_name = MpfSteam.get_lobby_data(lobby_id, "host")
		lobby.owner_id = str(MpfSteam.lobby_owner(lobby_id))
		lobby.game_version = MpfSteam.get_lobby_data(lobby_id, "version")
		lobby.player_count = MpfSteam.lobby_member_count(lobby_id)
		lobby.max_players = int(MpfSteam.get_lobby_data(lobby_id, "max"))
		lobby.has_password = MpfSteam.get_lobby_data(lobby_id, "pw") == "1"
		_steam_lobbies.append(lobby)
	list_updated.emit(_steam_lobbies)


func _on_steam_join_requested(lobby_id: int, _friend_id: int) -> void:
	var lobby := MpfLobby.new()
	lobby.source = &"steam"
	lobby.id = str(lobby_id)
	invite_accepted.emit(lobby)


func _on_lan_list_changed(found: Array[MpfLobby]) -> void:
	if not use_steam:
		list_updated.emit(found)


static func _visibility_code(visibility: Variant) -> int:
	match String(visibility).to_lower():
		"private":
			return MpfSteam.LOBBY_PRIVATE
		"friends":
			return MpfSteam.LOBBY_FRIENDS_ONLY
		"invisible":
			return MpfSteam.LOBBY_INVISIBLE
		_:
			return MpfSteam.LOBBY_PUBLIC
