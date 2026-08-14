extends SceneTree
## Reports exactly which pieces of the Steam stack are present.
##
##     godot --headless --path . --script res://tools/steam_check.gd
##
## Run it after each install step. Everything MPF needs is resolved by name at
## runtime, so this checks the same things the framework itself checks.

const PEER_CLASSES: PackedStringArray = ["SteamMultiplayerPeer", "SteamMultiplayerPeerExtension"]

## Methods MPF relies on. Names are tried in several spellings because
## GodotSteam has changed them across versions.
const REQUIRED := {
	"init": ["steamInitEx", "steam_init_ex", "steamInit", "steam_init"],
	"identity": ["getSteamID", "get_steam_id"],
	"persona": ["getPersonaName", "get_persona_name"],
	"callbacks": ["run_callbacks", "runCallbacks"],
	"create lobby": ["createLobby", "create_lobby"],
	"join lobby": ["joinLobby", "join_lobby"],
	"lobby data": ["setLobbyData", "set_lobby_data"],
	"lobby list": ["requestLobbyList", "request_lobby_list"],
	"invite overlay": ["activateGameOverlayInviteDialog", "activate_game_overlay_invite_dialog"],
	"cloud write": ["fileWrite", "file_write"],
	"cloud read": ["fileRead", "file_read"],
}

const SIGNALS: PackedStringArray = [
	"lobby_created", "lobby_joined", "lobby_match_list", "join_requested",
]


func _initialize() -> void:
	print("\n=== MPF Steam readiness ===\n")
	var blocking := 0

	var steam := Engine.get_singleton("Steam") if Engine.has_singleton("Steam") else null
	if steam == null:
		_fail("GodotSteam singleton", "not found - the GDExtension is not installed or failed to load")
		blocking += 1
	else:
		_pass("GodotSteam singleton", "found")
		for label: String in REQUIRED:
			var found := ""
			for name: Variant in REQUIRED[label]:
				if steam.has_method(String(name)):
					found = String(name)
					break
			if found == "":
				_fail("  api: %s" % label, "no known spelling present")
				blocking += 1
			else:
				_pass("  api: %s" % label, found)
		for signal_name: String in SIGNALS:
			if steam.has_signal(signal_name):
				_pass("  signal: %s" % signal_name, "present")
			else:
				_fail("  signal: %s" % signal_name, "missing")
				blocking += 1

	var peer := ""
	for cls: String in PEER_CLASSES:
		if ClassDB.class_exists(cls) and ClassDB.can_instantiate(cls):
			peer = cls
			break
	if peer == "":
		_fail("Steam multiplayer peer", "no SteamMultiplayerPeer class registered - lobbies would work but P2P would not")
		blocking += 1
	else:
		_pass("Steam multiplayer peer", peer)

	var app_id := int(ProjectSettings.get_setting("mpf/network/steam_app_id", 0))
	if app_id == 0:
		_fail("mpf/network/steam_app_id", "unset")
	elif app_id == 480:
		_warn("mpf/network/steam_app_id", "480 is Valve's Spacewar test app - fine for testing, must not ship")
	else:
		_pass("mpf/network/steam_app_id", str(app_id))

	if bool(ProjectSettings.get_setting("mpf/network/experimental_steam", false)):
		_warn("mpf/network/experimental_steam", "enabled - the transport is still unverified against real Steam")
	else:
		_fail("mpf/network/experimental_steam", "disabled - Steam will fall back to ENet")

	# The editor and an unpackaged build both need this file beside the binary,
	# unless the process was launched by Steam itself.
	var beside_binary := OS.get_executable_path().get_base_dir().path_join("steam_appid.txt")
	if FileAccess.file_exists(beside_binary):
		_pass("steam_appid.txt", beside_binary)
	else:
		_warn("steam_appid.txt", "not next to %s - Steam cannot initialise unless launched from Steam" % OS.get_executable_path().get_file())

	print("")
	if blocking == 0:
		print("READY - every required piece is present")
	else:
		print("NOT READY - %d blocking item(s); MPF will use ENet" % blocking)
	quit(0 if blocking == 0 else 1)


func _pass(label: String, detail: String) -> void:
	print("  [ ok ] %-32s %s" % [label, detail])


func _warn(label: String, detail: String) -> void:
	print("  [warn] %-32s %s" % [label, detail])


func _fail(label: String, detail: String) -> void:
	print("  [FAIL] %-32s %s" % [label, detail])
