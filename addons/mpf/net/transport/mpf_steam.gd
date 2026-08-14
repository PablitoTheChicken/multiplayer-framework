class_name MpfSteam
extends RefCounted
## Dynamic bridge to GodotSteam.
##
## Every call is resolved by name at runtime, so the framework compiles, runs
## and ships without GodotSteam installed - Steam features simply report
## unavailable. Method names are tried in several spellings and arguments are
## trimmed to fit, because GodotSteam has changed both across versions.

const LOBBY_PRIVATE := 0
const LOBBY_FRIENDS_ONLY := 1
const LOBBY_PUBLIC := 2
const LOBBY_INVISIBLE := 3

const PEER_CLASSES: PackedStringArray = ["SteamMultiplayerPeer", "SteamMultiplayerPeerExtension"]

static var initialized: bool = false


static func api() -> Object:
	return Engine.get_singleton("Steam") if Engine.has_singleton("Steam") else null


## The addon is present. This says nothing about whether Steam will answer.
static func is_available() -> bool:
	return api() != null


## The addon is present AND Steam initialised successfully, which is what any
## call that actually talks to Steam needs. Installing the addon must never be
## enough on its own to change behaviour: a player without the Steam client
## running would silently lose whatever was routed through it.
static func is_ready() -> bool:
	return initialized and api() != null


static func has_peer_class() -> bool:
	for cls: String in PEER_CLASSES:
		if ClassDB.class_exists(cls) and ClassDB.can_instantiate(cls):
			return true
	return false


static func make_peer() -> MultiplayerPeer:
	for cls: String in PEER_CLASSES:
		if ClassDB.class_exists(cls) and ClassDB.can_instantiate(cls):
			return ClassDB.instantiate(cls) as MultiplayerPeer
	return null


## Calls the first method that exists on [param object], padding or trimming
## [param args] to the signature it actually declares.
static func invoke_on(object: Object, names: Array, args: Array = [], fallback: Variant = null) -> Variant:
	if object == null:
		return fallback
	for raw_name: Variant in names:
		var method := String(raw_name)
		if not object.has_method(method):
			continue
		var info := _method_info(object, method)
		if info.is_empty():
			return object.callv(method, args)
		var declared := (info.get("args", []) as Array).size()
		var defaults := (info.get("default_args", []) as Array).size()
		var call_args := args.duplicate()
		if call_args.size() > declared:
			call_args.resize(declared)
		if call_args.size() < declared - defaults:
			continue
		return object.callv(method, call_args)
	return fallback


static func invoke(names: Array, args: Array = [], fallback: Variant = null) -> Variant:
	return invoke_on(api(), names, args, fallback)


static func listen(signal_name: String, callback: Callable) -> bool:
	var steam := api()
	if steam == null or not steam.has_signal(signal_name):
		return false
	if steam.is_connected(signal_name, callback):
		return true
	return steam.connect(signal_name, callback) == OK


static func initialize(app_id: int = 0) -> bool:
	if initialized:
		return true
	if not is_available():
		return false
	if app_id > 0:
		OS.set_environment("SteamAppId", str(app_id))
		OS.set_environment("SteamGameId", str(app_id))
	# Argument order is (app_id, embed_callbacks). Passing them the other way
	# round initialises app 0 and silently fails.
	var result: Variant = invoke(["steamInitEx", "steam_init_ex", "steamInit", "steam_init"], [app_id, false])
	initialized = _init_ok(result)
	MpfLog.info("net", "Steam init", {"ok": initialized, "app_id": app_id, "result": result})
	return initialized


## True when the Steam client is actually running and logged in. Distinct from
## the addon merely being installed.
static func is_running() -> bool:
	return bool(invoke(["isSteamRunning", "is_steam_running"], [], false))


## Ticket proving this account is who it claims. The server validates it with
## [method begin_auth_session], which is the only way to trust a Steam id that
## arrived over the wire.
static func auth_ticket() -> Dictionary:
	var result: Variant = invoke(["getAuthSessionTicket", "get_auth_session_ticket"], [0], {})
	return result if typeof(result) == TYPE_DICTIONARY else {}


## Returns Steam's begin-auth result code; 0 means the ticket was accepted for
## checking. The verdict itself arrives on validate_auth_ticket_response.
static func begin_auth_session(ticket: PackedByteArray, steam_id: int) -> int:
	return int(invoke(["beginAuthSession", "begin_auth_session"], [ticket, ticket.size(), steam_id], -1))


static func end_auth_session(steam_id: int) -> void:
	invoke(["endAuthSession", "end_auth_session"], [steam_id])


static func _init_ok(result: Variant) -> bool:
	match typeof(result):
		TYPE_DICTIONARY:
			return int((result as Dictionary).get("status", 1)) == 0
		TYPE_BOOL:
			return bool(result)
		TYPE_INT:
			return int(result) <= 1
		_:
			return result != null


static func run_callbacks() -> void:
	invoke(["run_callbacks", "runCallbacks"])


static func steam_id() -> int:
	return int(invoke(["getSteamID", "get_steam_id"], [], 0))


static func persona_name() -> String:
	return String(invoke(["getPersonaName", "get_persona_name"], [], ""))


static func friend_name(id: int) -> String:
	return String(invoke(["getFriendPersonaName", "get_friend_persona_name"], [id], ""))


static func create_lobby(type: int, max_members: int) -> void:
	invoke(["createLobby", "create_lobby"], [type, max_members])


static func join_lobby(lobby_id: int) -> void:
	invoke(["joinLobby", "join_lobby"], [lobby_id])


static func leave_lobby(lobby_id: int) -> void:
	invoke(["leaveLobby", "leave_lobby"], [lobby_id])


static func set_lobby_data(lobby_id: int, key: String, value: String) -> void:
	invoke(["setLobbyData", "set_lobby_data"], [lobby_id, key, value])


static func get_lobby_data(lobby_id: int, key: String) -> String:
	return String(invoke(["getLobbyData", "get_lobby_data"], [lobby_id, key], ""))


static func lobby_owner(lobby_id: int) -> int:
	return int(invoke(["getLobbyOwner", "get_lobby_owner"], [lobby_id], 0))


static func lobby_member_count(lobby_id: int) -> int:
	return int(invoke(["getNumLobbyMembers", "get_num_lobby_members"], [lobby_id], 0))


static func lobby_member_by_index(lobby_id: int, index: int) -> int:
	return int(invoke(["getLobbyMemberByIndex", "get_lobby_member_by_index"], [lobby_id, index], 0))


static func lobby_members(lobby_id: int) -> PackedInt64Array:
	var out := PackedInt64Array()
	for i: int in lobby_member_count(lobby_id):
		var member := lobby_member_by_index(lobby_id, i)
		if member != 0:
			out.append(member)
	return out


static func set_lobby_joinable(lobby_id: int, joinable: bool) -> void:
	invoke(["setLobbyJoinable", "set_lobby_joinable"], [lobby_id, joinable])


static func set_lobby_type(lobby_id: int, type: int) -> void:
	invoke(["setLobbyType", "set_lobby_type"], [lobby_id, type])


## Shown in a friend's Steam list, and what makes "Join game" work from the
## friends menu rather than only from an invite.
static func set_rich_presence(key: String, value: String) -> void:
	invoke(["setRichPresence", "set_rich_presence"], [key, value])


static func clear_rich_presence() -> void:
	invoke(["clearRichPresence", "clear_rich_presence"])


static func request_lobby_list() -> void:
	invoke(["requestLobbyList", "request_lobby_list"])


static func filter_lobbies_by(key: String, value: String, comparison: int = 0) -> void:
	invoke([
		"addRequestLobbyListStringFilter",
		"add_request_lobby_list_string_filter",
	], [key, value, comparison])


static func limit_lobby_results(count: int) -> void:
	invoke(["addRequestLobbyListResultCountFilter", "add_request_lobby_list_result_count_filter"], [count])


static func open_invite_overlay(lobby_id: int) -> void:
	invoke(["activateGameOverlayInviteDialog", "activate_game_overlay_invite_dialog"], [lobby_id])


static func cloud_write(file_name: String, data: PackedByteArray) -> bool:
	var result: Variant = invoke(["fileWrite", "file_write"], [file_name, data, data.size()], false)
	return bool(result)


static func cloud_read(file_name: String) -> PackedByteArray:
	var size := int(invoke(["getFileSize", "get_file_size"], [file_name], 0))
	if size <= 0:
		return PackedByteArray()
	var result: Variant = invoke(["fileRead", "file_read"], [file_name, size], null)
	if typeof(result) == TYPE_DICTIONARY:
		return (result as Dictionary).get("buf", PackedByteArray()) as PackedByteArray
	if typeof(result) == TYPE_PACKED_BYTE_ARRAY:
		return result
	return PackedByteArray()


static func cloud_exists(file_name: String) -> bool:
	return bool(invoke(["fileExists", "file_exists"], [file_name], false))


static func cloud_delete(file_name: String) -> bool:
	return bool(invoke(["fileDelete", "file_delete"], [file_name], false))


static func cloud_list() -> PackedStringArray:
	var out := PackedStringArray()
	var count := int(invoke(["getFileCount", "get_file_count"], [], 0))
	for i: int in count:
		var entry: Variant = invoke(["getFileNameAndSize", "get_file_name_and_size"], [i], null)
		if typeof(entry) == TYPE_DICTIONARY:
			out.append(String((entry as Dictionary).get("name", "")))
	return out


## Steam launches the game with `+connect_lobby <id>` when a player accepts an
## invite from outside the game. Without reading it, accepting an invite while
## the game is closed silently does nothing.
static func launch_lobby_id() -> int:
	var args := MpfUtil.cli_args()
	for key: String in ["connect_lobby", "connect-lobby"]:
		if args.has(key):
			var value := str(args[key])
			if value.is_valid_int():
				return int(value)
	# Steam passes it as a bare `+connect_lobby 123` pair, which is not a flag.
	var argv := OS.get_cmdline_args()
	for i: int in argv.size() - 1:
		if String(argv[i]) == "+connect_lobby" and String(argv[i + 1]).is_valid_int():
			return int(String(argv[i + 1]))
	return 0


static func _method_info(object: Object, method: String) -> Dictionary:
	for info: Dictionary in object.get_method_list():
		if String(info.get("name", "")) == method:
			return info
	return {}
