extends SceneTree
## Dumps the real signatures MPF depends on, so the transport can be written
## against facts instead of guesses about which GodotSteam version is present.
##
##     godot --headless --path . --script res://tools/steam_introspect.gd

const PEER_METHODS: PackedStringArray = [
	"create_host", "create_client", "createHost", "createClient",
	"close", "get_peer", "set_target_peer", "poll",
]

const STEAM_METHODS: PackedStringArray = [
	"steamInitEx", "steamInit", "getSteamID", "run_callbacks",
	"getAuthSessionTicket", "beginAuthSession", "endAuthSession",
	"getLobbyMemberByIndex", "setLobbyJoinable", "setLobbyType",
	"setRichPresence", "clearRichPresence", "getLobbyMemberData",
	"setLobbyMemberData", "setLobbyOwner", "isSteamRunning",
]


func _initialize() -> void:
	print("\n=== SteamMultiplayerPeer ===")
	for cls: String in ["SteamMultiplayerPeer", "SteamMultiplayerPeerExtension"]:
		if not ClassDB.class_exists(cls):
			print("  %s: not registered" % cls)
			continue
		print("  %s: registered (instantiable=%s, inherits=%s)" % [
			cls, ClassDB.can_instantiate(cls), ClassDB.get_parent_class(cls),
		])
		for method: String in PEER_METHODS:
			if ClassDB.class_has_method(cls, method, true):
				print("    %s" % _signature(ClassDB.class_get_method_list(cls, true), method))
		print("    -- signals --")
		for info: Dictionary in ClassDB.class_get_signal_list(cls, true):
			print("      %s" % info["name"])
		print("    -- properties --")
		for info: Dictionary in ClassDB.class_get_property_list(cls, true):
			var name := String(info["name"])
			if not name.begins_with("_"):
				print("      %s: %s" % [name, type_string(int(info["type"]))])

	print("\n=== Steam singleton ===")
	var steam := Engine.get_singleton("Steam") if Engine.has_singleton("Steam") else null
	if steam == null:
		print("  not installed")
		quit(1)
		return
	var all := steam.get_method_list()
	print("  %d methods total" % all.size())
	for method: String in STEAM_METHODS:
		print("  %s" % _signature(all, method))

	print("\n=== signals carrying peer identity ===")
	for info: Dictionary in steam.get_signal_list():
		var name := String(info["name"])
		if name.contains("lobby") or name.contains("p2p") or name.contains("auth") or name.contains("join"):
			var args := PackedStringArray()
			for arg: Dictionary in info.get("args", []):
				args.append("%s: %s" % [arg["name"], type_string(int(arg["type"]))])
			print("  %s(%s)" % [name, ", ".join(args)])
	quit(0)


static func _signature(methods: Array, wanted: String) -> String:
	for info: Dictionary in methods:
		if String(info.get("name", "")) != wanted:
			continue
		var args := PackedStringArray()
		for arg: Dictionary in info.get("args", []):
			args.append("%s: %s" % [arg["name"], type_string(int(arg["type"]))])
		var defaults := (info.get("default_args", []) as Array).size()
		return "%s(%s)%s -> %s" % [
			wanted, ", ".join(args),
			"  [%d optional]" % defaults if defaults > 0 else "",
			type_string(int((info.get("return", {}) as Dictionary).get("type", TYPE_NIL))),
		]
	return "%s: ABSENT" % wanted
