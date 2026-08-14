extends Node3D
## End-to-end sandbox: session control, spawning, replicated movement, a
## server-validated proximity action and per-player persistence.

const PORT := 27015
const PLAYER_SCENE := preload("res://examples/sandbox/player.tscn")

@onready var world: MpfNetWorld = $NetWorld
@onready var status: Label = $UI/Panel/Status
@onready var hint: Label = $UI/Panel/Hint
@onready var prompt: Label = $UI/Panel/Prompt

var _players: Dictionary = {}
var _found_lobbies: Array[MpfLobby] = []


func _ready() -> void:
	world.register_scene(&"player", PLAYER_SCENE)
	Net.session_started.connect(_on_session_started)
	Net.session_ended.connect(_on_session_ended)
	Net.peer_joined.connect(_on_peer_joined)
	# Spawn on peer_ready, not peer_joined: a joiner may still be loading the
	# scene, and anything spawned before then never reaches it.
	Net.peer_ready.connect(_on_peer_ready)
	Net.peer_left.connect(_on_peer_left)
	Net.lobbies_updated.connect(_on_lobbies_updated)
	MPF.events.on(&"prompt", _on_prompt)
	Save.players.register_field(&"sessions", 0, MpfPlayerData.Scope.OWNER)
	hint.text = "WASD move   mouse look   Space jump   E interact   Esc free cursor\n[1] host LAN   [2] join 127.0.0.1   [3] single player   [0] leave\n[5] host via Steam   then on the OTHER peer: [4] find lobbies   [6] join first found"
	prompt.text = ""
	_start_from_cli()


## Lets two instances be launched straight into a session instead of pressing
## keys in each window: `--host`, or `--join` / `--join=192.168.1.20:27015`.
## `--server` is handled one level down by Net itself and runs headless.
func _start_from_cli() -> void:
	if not Net.is_offline():
		return
	var args := MpfUtil.cli_args()
	# Net handles --server/--dedicated itself, one frame later. Starting an
	# offline session here first would tear it straight back down.
	if args.has("server") or args.has("dedicated"):
		return
	Net.set_local_name(str(args.get("name", "Player%d" % (randi() % 900 + 100))))
	if args.has("host"):
		Net.host({"transport": "enet", "port": PORT, "lobby_name": "Sandbox"})
	elif args.has("join"):
		var where: Variant = args["join"]
		Net.join("127.0.0.1:%d" % PORT if typeof(where) == TYPE_BOOL else str(where))
	else:
		Net.host_offline()


func _process(_delta: float) -> void:
	var lines := PackedStringArray()
	lines.append("MPF %s   %s   %s" % [MPF.VERSION, _role_text(), _status_text()])
	lines.append("players %d/%d   entities %d   rtt %.0f ms" % [
		Net.player_count(), Net.max_players(), Net.entity_count(), Net.rtt()
	])
	lines.append("steam: %s" % _steam_text())
	for peer: MpfPeer in Net.peers():
		var sessions: int = int(Save.players.get_for(peer.id).get_value(&"sessions", 0))
		lines.append("  #%d %s%s   sessions %d" % [
			peer.id, peer.display_name, "  (you)" if peer.is_local else "", sessions
		])
	if not _found_lobbies.is_empty():
		lines.append("lobbies found (press 6 to join the first):")
		for lobby: MpfLobby in _found_lobbies:
			lines.append("  [%s] %s  %d/%d  -> %s" % [
				lobby.source, lobby.name, lobby.player_count, lobby.max_players, lobby.connect_target(),
			])
	status.text = "\n".join(lines)


func _unhandled_key_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	match key.keycode:
		KEY_1:
			Net.host({"transport": "enet", "port": PORT, "lobby_name": "Sandbox"})
		KEY_2:
			Net.join("127.0.0.1:%d" % PORT)
		KEY_3:
			Net.host_offline()
		KEY_4:
			_found_lobbies.clear()
			MPF.events.emit(&"prompt", {"text": "Searching for lobbies..."})
			Net.refresh_lobbies()
		KEY_5:
			# Hosting over Steam is what initialises Steam, so lobby listing
			# only finds Steam lobbies once something has done this.
			Net.host({"transport": "steam", "lobby_name": "Sandbox"})
		KEY_6:
			# Press 4 first to populate the list. One peer hosts with 5, the
			# other discovers with 4 and joins with 6 - pressing 5 on both
			# just creates two separate lobbies.
			if _found_lobbies.is_empty():
				MPF.events.emit(&"prompt", {"text": "No lobbies found - press 4 to search"})
			else:
				MpfLog.info("demo", "Joining", {"lobby": str(_found_lobbies[0])})
				Net.join(_found_lobbies[0])
		KEY_0:
			Net.leave("quit to menu")


func _on_session_started(_role: int) -> void:
	if not Net.is_server():
		return
	for peer: MpfPeer in Net.ready_peers():
		_spawn_player(peer.id)


func _on_session_ended(_reason: String) -> void:
	_players.clear()


func _on_peer_joined(peer: MpfPeer) -> void:
	if not Net.is_server():
		return
	Save.players.get_for(peer.id).add(&"sessions", 1)
	Save.players.replicate(peer.id)


func _on_peer_ready(peer: MpfPeer) -> void:
	if Net.is_server():
		_spawn_player(peer.id)


func _on_peer_left(peer: MpfPeer, _reason: String) -> void:
	var node: Node = _players.get(peer.id)
	if is_instance_valid(node):
		world.despawn(node)
	_players.erase(peer.id)


func _on_lobbies_updated(found: Array[MpfLobby]) -> void:
	_found_lobbies = found
	MPF.events.emit(&"prompt", {"text": "Search returned %d lobby(s)" % found.size()})
	MpfLog.info("demo", "Lobbies found", {"count": found.size()})
	for lobby: MpfLobby in found:
		MpfLog.info("demo", "  %s" % lobby, {"target": lobby.connect_target()})


func _on_prompt(payload: Dictionary) -> void:
	prompt.text = String(payload.get("text", ""))


func _spawn_player(peer_id: int) -> void:
	if _players.has(peer_id):
		return
	var node := world.spawn(&"player", {
		"spawn_position": Vector3(randf_range(-4.0, 4.0), 1.2, randf_range(-4.0, 4.0)),
	}, peer_id)
	if node != null:
		_players[peer_id] = node


## Searching that returns nothing is ambiguous unless you can see whether Steam
## is even up, which is exactly the confusion this line exists to remove.
func _steam_text() -> String:
	if not MpfSteam.is_available():
		return "addon not installed"
	if not MpfSteam.is_ready():
		return "not initialised (press 4 or 5)"
	return "ready as %s (%d)" % [MpfSteam.persona_name(), MpfSteam.steam_id()]


func _role_text() -> String:
	if Net.is_offline():
		return "offline"
	return "server" if Net.is_server() else "client"


func _status_text() -> String:
	match Net.status:
		Net.Status.CONNECTING:
			return "connecting"
		Net.Status.ONLINE:
			return "online (%s)" % (String(Net.transport.id()) if Net.transport != null else "-")
		Net.Status.FAILED:
			return "failed: %s" % Net.last_error()
		_:
			return "idle"
