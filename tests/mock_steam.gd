class_name MockSteam
extends Object
## Stand-in for the GodotSteam singleton, so the Steam code paths can actually
## be executed in tests.
##
## GodotSteam is a native extension that cannot be installed in CI, which is why
## the Steam layer sat at zero coverage. [MpfSteam] resolves everything by name
## through [method Engine.get_singleton], so registering this object under the
## name "Steam" makes it the thing that gets called.
##
## It mimics the real API's shape - camelCase names, dictionary returns, signals
## fired asynchronously - not its behaviour. It proves MPF talks to Steam
## correctly; it cannot prove Steam answers the way we expect.

signal lobby_created(connect_result: int, lobby_id: int)
signal lobby_joined(lobby_id: int, permissions: int, locked: bool, response: int)
signal lobby_match_list(lobbies: Array)
signal join_requested(lobby_id: int, friend_id: int)

const SELF_ID := 76561190000000001

var initialised := false
var callbacks_run := 0
var lobbies: Dictionary = {}
var joined_lobby := 0
var files: Dictionary = {}
var overlay_invites: Array = []
var last_filters: Dictionary = {}

var _next_lobby := 100


static func install() -> MockSteam:
	var mock := MockSteam.new()
	if Engine.has_singleton("Steam"):
		Engine.unregister_singleton("Steam")
	Engine.register_singleton("Steam", mock)
	MpfSteam.initialized = false
	return mock


static func uninstall() -> void:
	if Engine.has_singleton("Steam"):
		var existing := Engine.get_singleton("Steam")
		Engine.unregister_singleton("Steam")
		# Unregistering does not free it, and Object has no reference counting.
		if existing is MockSteam:
			existing.free()
	MpfSteam.initialized = false


# --- lifecycle --------------------------------------------------------------

func steamInitEx(_embed: bool = false, _app_id: int = 0) -> Dictionary:
	initialised = true
	return {"status": 0, "verbal": "ok"}


func run_callbacks() -> void:
	callbacks_run += 1


func getSteamID() -> int:
	return SELF_ID


func getPersonaName() -> String:
	return "MockPlayer"


func getFriendPersonaName(_id: int) -> String:
	return "MockFriend"


# --- lobbies ----------------------------------------------------------------

func createLobby(type: int, max_members: int) -> void:
	_next_lobby += 1
	var id := _next_lobby
	lobbies[id] = {"type": type, "max": max_members, "owner": SELF_ID, "data": {}, "members": 1}
	# The real API answers on a callback, never inline.
	lobby_created.emit.call_deferred(1, id)


func joinLobby(lobby_id: int) -> void:
	if not lobbies.has(lobby_id):
		lobby_joined.emit.call_deferred(lobby_id, 0, false, 2)
		return
	joined_lobby = lobby_id
	lobby_joined.emit.call_deferred(lobby_id, 0, false, 1)


func leaveLobby(lobby_id: int) -> void:
	if joined_lobby == lobby_id:
		joined_lobby = 0


func setLobbyData(lobby_id: int, key: String, value: String) -> bool:
	if not lobbies.has(lobby_id):
		return false
	(lobbies[lobby_id]["data"] as Dictionary)[key] = value
	return true


func getLobbyData(lobby_id: int, key: String) -> String:
	if not lobbies.has(lobby_id):
		return ""
	return String((lobbies[lobby_id]["data"] as Dictionary).get(key, ""))


func getLobbyOwner(lobby_id: int) -> int:
	return int(lobbies.get(lobby_id, {}).get("owner", 0))


func getNumLobbyMembers(lobby_id: int) -> int:
	return int(lobbies.get(lobby_id, {}).get("members", 0))


func requestLobbyList() -> void:
	lobby_match_list.emit.call_deferred(lobbies.keys())


func addRequestLobbyListStringFilter(key: String, value: String, comparison: int) -> void:
	last_filters[key] = {"value": value, "comparison": comparison}


func addRequestLobbyListResultCountFilter(count: int) -> void:
	last_filters["_limit"] = count


func activateGameOverlayInviteDialog(lobby_id: int) -> void:
	overlay_invites.append(lobby_id)


# --- remote storage ---------------------------------------------------------

func fileWrite(file_name: String, data: PackedByteArray, _size: int) -> bool:
	files[file_name] = data
	return true


func fileRead(file_name: String, _size: int) -> Dictionary:
	if not files.has(file_name):
		return {"ret": false, "buf": PackedByteArray()}
	return {"ret": true, "buf": files[file_name]}


func getFileSize(file_name: String) -> int:
	return (files[file_name] as PackedByteArray).size() if files.has(file_name) else 0


func fileExists(file_name: String) -> bool:
	return files.has(file_name)


func fileDelete(file_name: String) -> bool:
	return files.erase(file_name)


func getFileCount() -> int:
	return files.size()


func getFileNameAndSize(index: int) -> Dictionary:
	var names := files.keys()
	if index < 0 or index >= names.size():
		return {"name": "", "size": 0}
	return {"name": names[index], "size": (files[names[index]] as PackedByteArray).size()}
