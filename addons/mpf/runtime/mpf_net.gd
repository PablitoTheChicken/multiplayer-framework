extends Node
## Net autoload. Sessions, peers, and all message routing.
##
## One API covers single player, listen servers, dedicated servers and Steam
## P2P; only the transport changes. Registered by the plugin.

signal status_changed(status: int)
signal session_started(role: int)
signal session_ended(reason: String)
signal connection_failed(reason: String)
signal kicked(reason: String)
signal peer_joined(peer: MpfPeer)
## The peer has finished loading the server's scene and can receive spawns.
## Spawn entities here rather than on [signal peer_joined].
signal peer_ready(peer: MpfPeer)
signal peer_left(peer: MpfPeer, reason: String)
## A peer reclaimed a slot held open for it. Restore its avatar here rather
## than spawning a fresh one.
signal peer_resumed(peer: MpfPeer, previous_id: int)
signal scene_changing(path: String)
signal scene_changed(path: String)
signal peer_meta_changed(peer: MpfPeer)
signal lobbies_updated(lobbies: Array[MpfLobby])
signal invite_accepted(lobby: MpfLobby)

enum Role { NONE, SERVER, CLIENT }
enum Status { OFFLINE, STARTING, CONNECTING, ONLINE, FAILED }

const DEFAULT_PORT := 27015
const PING_INTERVAL := 1.0
const MAX_NAME_LENGTH := 24
const SERVER_ID := 1

var role: Role = Role.NONE
var status: Status = Status.OFFLINE
## True for a server with no local player.
var dedicated: bool = false
var transport: MpfTransport = null
var lobbies: MpfLobbyService = null
var time: MpfNetTime = null
## Active session configuration, after defaults are merged in.
var config: Dictionary = {}
## Name this machine presents during the handshake.
var local_name: String = "Player"
## Active [MpfNetWorld], set when one enters the tree.
var world: Node = null
## Scene the server has declared authoritative. Empty means the game is not
## using scene sync and every peer is assumed to already be in the right place.
var current_scene: String = ""

var _peers: Dictionary = {}
var _pending: Dictionary = {}
var _channels: Dictionary = {}
var _batches: Dictionary = {}
var _targeted: Dictionary = {}
var _limiters: Dictionary = {}
var _next_net_id: int = 1
var _entities: Dictionary = {}
var _receivers: Dictionary = {}
var _player_nodes: Dictionary = {}
var _relevancy: Dictionary = {}
var _replicators: Array = []
var _by_entity: Dictionary = {}
var _relevant: Dictionary = {}
var _budgets: Dictionary = {}
var _reserved: Dictionary = {}
var _ping_timer: float = 0.0
var _connect_deadline: int = 0
var _last_error: String = ""

## Optional `func(peer_id: int) -> Vector3` giving the point relevancy is
## measured from. Defaults to the peer's registered avatar, which is right for
## most games; override it for spectators or vehicle cameras.
var relevancy_origin: Callable = Callable()

## Debug network conditioning, applied to inbound messages before dispatch.
## Loopback delivers instantly and never drops anything, which hides every
## interpolation and ordering bug you have. Turn these on to find them.
## Only unreliable channels are dropped, because the transport would have
## redelivered a reliable one.
var simulate_latency_ms: float = 0.0
var simulate_jitter_ms: float = 0.0
var simulate_loss: float = 0.0

var _delayed: Array = []


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	time = MpfNetTime.new()
	lobbies = MpfLobbyService.new()
	lobbies.name = "Lobbies"
	add_child(lobbies)
	lobbies.resolved.connect(_on_lobby_resolved)
	lobbies.failed.connect(_on_lobby_failed)
	lobbies.list_updated.connect(func(found: Array[MpfLobby]) -> void: lobbies_updated.emit(found))
	lobbies.invite_accepted.connect(func(lobby: MpfLobby) -> void: invite_accepted.emit(lobby))

	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)

	_register_internal_channels()
	var root := MpfRuntime.root()
	if root != null:
		root.tick.tick.connect(_on_tick)
	if bool(ProjectSettings.get_setting("mpf/network/cli_dedicated", true)):
		_bootstrap_from_cli.call_deferred()


func _process(delta: float) -> void:
	# Steam answers everything through callbacks - lobby created, lobby list,
	# invites - and they only fire while this is pumped. Leaving it to the
	# transport meant a peer that was browsing rather than playing had Steam
	# initialised but deaf: requests went out and no reply ever arrived.
	if MpfSteam.initialized:
		MpfSteam.run_callbacks()
	if transport != null:
		transport.poll(delta)
	if not _delayed.is_empty():
		_flush_delayed()
	if _connect_deadline > 0 and Time.get_ticks_msec() > _connect_deadline:
		_connect_deadline = 0
		var reason := "timed out while connecting"
		MpfLog.warn("net", "Connection attempt timed out")
		leave(reason)
		connection_failed.emit(reason)
	if status == Status.ONLINE and role != Role.NONE:
		_ping_timer += delta
		if _ping_timer >= PING_INTERVAL:
			_ping_timer = 0.0
			if role == Role.CLIENT:
				send_to_server(&"__ping", {"t": MpfNetTime.local_ms()})
			else:
				for id: int in multiplayer.get_peers():
					send_to(&"__ping", id, {"t": MpfNetTime.local_ms()})
	if role == Role.SERVER:
		_expire_pending()
		_expire_silent()


# --- Session ----------------------------------------------------------------

## Starts a server. Completion is reported by [signal session_started]; the
## returned bool only says the attempt was accepted.
func host(options: Dictionary = {}) -> bool:
	if role != Role.NONE:
		leave("restarting")
	config = MpfUtil.deep_merge(defaults(), options)
	dedicated = bool(config["dedicated"])
	transport = _make_transport(String(config["transport"]), null)
	if transport == null:
		return _start_failed("no usable transport")
	var peer := transport.create_server(config)
	if peer == null:
		return _start_failed(transport.last_error)
	multiplayer.multiplayer_peer = peer
	role = Role.SERVER
	time.reset()
	if not dedicated:
		var me := _local_peer(SERVER_ID)
		me.authenticated = true
		me.scene_ready = true
		_peers[SERVER_ID] = me
	_set_status(Status.ONLINE)
	if bool(config["advertise"]) and String(config["transport"]) != "offline":
		lobbies.advertise(build_lobby(), transport.id() == &"steam")
	MpfLog.info("net", "Hosting", {"transport": String(transport.id()), "dedicated": dedicated})
	session_started.emit.call_deferred(int(role))
	if not dedicated:
		peer_joined.emit.call_deferred(_peers[SERVER_ID])
		peer_ready.emit.call_deferred(_peers[SERVER_ID])
	return true


## Convenience for a headless authoritative server with no local player.
func host_dedicated(port: int = DEFAULT_PORT, options: Dictionary = {}) -> bool:
	var merged := options.duplicate()
	merged["dedicated"] = true
	merged["port"] = port
	merged["transport"] = merged.get("transport", "enet")
	return host(merged)


## Starts single player. Everything stays authoritative locally.
func host_offline() -> bool:
	return host({"transport": "offline", "advertise": false, "max_players": 1})


## Connects to [param target]: an "ip:port" string, a Steam id, or an [MpfLobby].
func join(target: Variant, options: Dictionary = {}) -> bool:
	if role != Role.NONE:
		leave("reconnecting")
	config = MpfUtil.deep_merge(defaults(), options)
	if target is MpfLobby and (target as MpfLobby).source == &"steam":
		_set_status(Status.CONNECTING)
		lobbies.resolve(target)
		return true
	if target is MpfLobby:
		target = (target as MpfLobby).connect_target()
	return _connect(target)


func leave(reason: String = "left") -> void:
	if role == Role.NONE and status == Status.OFFLINE:
		return
	lobbies.leave()
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = null
	if transport != null:
		transport.shutdown()
	transport = null
	role = Role.NONE
	dedicated = false
	_peers.clear()
	_pending.clear()
	_batches.clear()
	_targeted.clear()
	_limiters.clear()
	_budgets.clear()
	_reserved.clear()
	_delayed.clear()
	_relevant.clear()
	# Entity registries deliberately survive: leaving a session does not unload
	# the scene, and scene-placed entities register in _ready(), which will not
	# run again. Clearing here would make every door and lever invisible to the
	# network after a leave-then-rehost. _apply_scene() clears them instead,
	# because there the tree really is being replaced.
	time.reset()
	_set_status(Status.OFFLINE)
	MpfLog.info("net", "Session ended", {"reason": reason})
	session_ended.emit(reason)


## Server only. Disconnects a peer with a reason it can display.
func kick(peer_id: int, reason: String = "kicked") -> void:
	if not is_server() or peer_id == SERVER_ID:
		return
	send_to(&"__kick", peer_id, {"reason": reason})
	_disconnect_later(peer_id)


func is_server() -> bool:
	return role != Role.CLIENT


func is_client() -> bool:
	return role == Role.CLIENT


func is_online() -> bool:
	return status == Status.ONLINE and role != Role.NONE


func is_offline() -> bool:
	return role == Role.NONE


func local_id() -> int:
	if role == Role.NONE or multiplayer.multiplayer_peer == null:
		return SERVER_ID
	return multiplayer.get_unique_id()


func peers() -> Array[MpfPeer]:
	var ids := _peers.keys()
	ids.sort()
	var out: Array[MpfPeer] = []
	for id: int in ids:
		out.append(_peers[id])
	return out


func peer(peer_id: int) -> MpfPeer:
	return _peers.get(peer_id)


func local_peer() -> MpfPeer:
	return _peers.get(local_id())


func peer_ids() -> PackedInt32Array:
	var ids := PackedInt32Array()
	for id: int in _peers.keys():
		ids.append(id)
	ids.sort()
	return ids


func player_count() -> int:
	return _peers.size()


func max_players() -> int:
	return int(config.get("max_players", 16))


## Shared clock in seconds. Identical on every peer once synced.
func server_time() -> float:
	return time.now() if role == Role.CLIENT else float(Time.get_ticks_msec()) * 0.001


func rtt(peer_id: int = 0) -> float:
	if peer_id == 0 or peer_id == local_id():
		return time.rtt_ms
	var found: MpfPeer = _peers.get(peer_id)
	return found.rtt_ms if found != null else 0.0


func last_error() -> String:
	return _last_error


func defaults() -> Dictionary:
	return {
		"transport": "auto",
		"port": DEFAULT_PORT,
		"bind_address": "*",
		"max_players": 16,
		"dedicated": false,
		"password": "",
		"game_version": String(ProjectSettings.get_setting("application/config/version", "")),
		"lobby_name": "",
		"lobby_visibility": "public",
		"advertise": true,
		"compression": true,
		"app_id": int(ProjectSettings.get_setting("mpf/network/steam_app_id", 0)),
		"auth_timeout": 10.0,
		# A connection attempt that stalls must end in a reported failure, not
		# a spinner. Lobby resolution, DNS and NAT traversal can all hang.
		"connect_timeout": 15.0,
		"peer_timeout": 12.0,
		"peer_message_budget": 240.0,
		"reconnect_grace": 120.0,
		# Off by default: a client asserting its own platform id can claim
		# anyone's save data. Only enable it where every peer is trusted.
		"trust_client_identity": false,
		"virtual_port": 0,
	}


## Describes the running session for advertising and for the join UI.
func build_lobby() -> MpfLobby:
	var lobby := MpfLobby.new()
	lobby.id = MpfUtil.short_id()
	lobby.name = String(config.get("lobby_name", "")) if String(config.get("lobby_name", "")) != "" else "%s's game" % local_name
	lobby.host_name = local_name
	lobby.port = int(config.get("port", DEFAULT_PORT))
	lobby.player_count = player_count()
	lobby.max_players = max_players()
	lobby.has_password = String(config.get("password", "")) != ""
	lobby.game_version = String(config.get("game_version", ""))
	lobby.data = {"visibility": config.get("lobby_visibility", "public")}
	return lobby


## Starts a lobby search. Results arrive on [signal lobbies_updated].
func refresh_lobbies(prefer_steam: bool = true) -> void:
	# Browsing happens before any session exists, so Steam has to be brought up
	# here or the search quietly falls back to LAN and reports nothing found.
	if prefer_steam:
		MpfSteam.ensure_initialized()
	lobbies.refresh(prefer_steam and MpfSteam.is_ready())


func invite_friends() -> bool:
	return lobbies.invite()


# --- Identity ---------------------------------------------------------------

func set_local_name(value: String) -> void:
	local_name = _clean_name(value)
	if is_online():
		send_to_server(&"__meta", {"name": local_name})


## Attaches replicated data to the local peer: team, loadout, ready state.
func set_local_meta(key: StringName, value: Variant) -> void:
	send_to_server(&"__meta", {"key": String(key), "value": value})


# --- Channels ---------------------------------------------------------------

## Registers a named channel. [param handler] takes (sender_id, payload).
## See [MpfChannel] for the option keys.
func register_channel(channel_name: StringName, handler: Callable, options: Dictionary = {}) -> void:
	if String(channel_name).begins_with("__") and not bool(options.get("internal", false)):
		MpfLog.error("net", "Names starting with __ are reserved", {"channel": String(channel_name)})
		return
	if _channels.has(channel_name) and not bool(options.get("replace", false)):
		MpfLog.warn("net", "Channel re-registered", {"channel": String(channel_name)})
	_channels[channel_name] = MpfChannel.create(channel_name, handler, options)


func unregister_channel(channel_name: StringName) -> void:
	_channels.erase(channel_name)


func has_channel(channel_name: StringName) -> bool:
	return _channels.has(channel_name)


## Sends to the server. On a server or offline this dispatches locally, so a
## host runs the same code path as a remote client.
func send_to_server(channel_name: StringName, payload: Variant) -> void:
	var channel: MpfChannel = _channels.get(channel_name)
	if channel == null:
		_unknown(channel_name)
		return
	if is_server():
		_invoke(channel, local_id(), payload)
		return
	_send_rpc(SERVER_ID, channel, payload)


## Server only. Sends to every client and dispatches locally unless the local
## id is in [param exclude].
func send_to_all(channel_name: StringName, payload: Variant, exclude: Array = []) -> void:
	var channel: MpfChannel = _channels.get(channel_name)
	if channel == null:
		_unknown(channel_name)
		return
	if not is_server():
		MpfLog.warn("net", "Only the server may broadcast", {"channel": String(channel_name)})
		return
	if not exclude.has(local_id()):
		_invoke(channel, local_id(), payload)
	if role == Role.NONE:
		return
	for id: int in multiplayer.get_peers():
		if not exclude.has(id):
			_send_rpc(id, channel, payload)


func send_to(channel_name: StringName, peer_id: int, payload: Variant) -> void:
	var channel: MpfChannel = _channels.get(channel_name)
	if channel == null:
		_unknown(channel_name)
		return
	if peer_id == local_id():
		_invoke(channel, local_id(), payload)
		return
	if role == Role.NONE:
		return
	_send_rpc(peer_id, channel, payload)


## Coalesces per-key updates and sends one batched message on the next tick.
## Repeated calls for the same key before the flush keep only the newest value.
func queue_update(channel_name: StringName, key: Variant, payload: Variant) -> void:
	var batch: Dictionary = _batches.get(channel_name, {})
	batch[key] = payload
	_batches[channel_name] = batch


## Same as [method queue_update] but addressed to one peer. Used to bring a
## late joiner up to date in a single packet instead of one per entity.
func queue_update_to(peer_id: int, channel_name: StringName, key: Variant, payload: Variant) -> void:
	var channels: Dictionary = _targeted.get(peer_id, {})
	var batch: Dictionary = channels.get(channel_name, {})
	batch[key] = payload
	channels[channel_name] = batch
	_targeted[peer_id] = channels


# --- Entity registry --------------------------------------------------------

## Server-allocated id for a runtime-spawned entity.
##
## Negative, because scene-placed entities derive a positive id from their path
## hash. Keeping the two ranges disjoint makes a collision impossible instead of
## merely unlikely. The counter never resets, so re-hosting cannot hand a fresh
## entity an id that a not-yet-freed node from the previous session still holds.
func allocate_net_id() -> int:
	_next_net_id += 1
	return -_next_net_id


func register_entity(net_id: int, node: Node) -> void:
	if net_id == 0:
		return
	if _entities.has(net_id) and _entities[net_id] != node:
		MpfLog.warn("net", "Duplicate net id", {"net_id": net_id})
	_entities[net_id] = node


## Pass [param node] so a late-freed entity cannot tear down the registration
## of a newer one that has since taken the same id.
func unregister_entity(net_id: int, node: Node = null) -> void:
	if node != null and _entities.get(net_id) != node:
		return
	_entities.erase(net_id)
	_receivers.erase(net_id)
	_relevancy.erase(net_id)


## Routes batched updates on [param channel_name] addressed to [param net_id].
## [param receiver] takes (sender_id, data) and returns whether it accepted the
## update; only accepted entries are relayed on to other clients.
func register_receiver(net_id: int, channel_name: StringName, receiver: Callable) -> void:
	var map: Dictionary = _receivers.get(net_id, {})
	map[channel_name] = receiver
	_receivers[net_id] = map


func unregister_receiver(net_id: int, channel_name: StringName) -> void:
	var map: Dictionary = _receivers.get(net_id, {})
	map.erase(channel_name)
	if map.is_empty():
		_receivers.erase(net_id)


func find_entity(net_id: int) -> Node:
	var node: Node = _entities.get(net_id)
	return node if is_instance_valid(node) else null


func entity_count() -> int:
	return _entities.size()


## Every registered net id, for world capture and debug tooling.
func entity_ids() -> Array:
	return _entities.keys()


## Associates a peer with its avatar. Filled in automatically by any
## [MpfNetIdentity] set to owner authority, and used for server-side range
## checks in [MpfAction].
func register_player_node(peer_id: int, node: Node) -> void:
	_player_nodes[peer_id] = node


func player_node(peer_id: int) -> Node:
	var node: Node = _player_nodes.get(peer_id)
	return node if is_instance_valid(node) else null


# --- Interest management ----------------------------------------------------

## Marks an entity as only relevant within [param range] of a peer. Registered
## automatically by [MpfNetIdentity] when its relevancy_range is above zero.
func register_relevancy(net_id: int, node: Node, range_metres: float) -> void:
	_relevancy[net_id] = {"node": node, "range": range_metres}


func unregister_relevancy(net_id: int) -> void:
	_relevancy.erase(net_id)


## Where relevancy is measured from for a peer, or `null` when unknown - in
## which case that peer receives everything, because silently starving a peer of
## updates is far worse than sending it too many.
func relevancy_point(peer_id: int) -> Variant:
	if relevancy_origin.is_valid():
		return relevancy_origin.call(peer_id)
	var node := player_node(peer_id)
	if node is Node3D:
		return (node as Node3D).global_position
	if node is Node2D:
		var flat := (node as Node2D).global_position
		return Vector3(flat.x, flat.y, 0.0)
	return null


func is_relevant_to(peer_id: int, net_id: int) -> bool:
	var entry: Dictionary = _relevancy.get(net_id, {})
	if entry.is_empty():
		return true
	var node: Node = entry["node"]
	if not is_instance_valid(node):
		return true
	var origin: Variant = relevancy_point(peer_id)
	if typeof(origin) != TYPE_VECTOR3:
		return true
	var here := Vector3.ZERO
	if node is Node3D:
		here = (node as Node3D).global_position
	elif node is Node2D:
		var flat := (node as Node2D).global_position
		here = Vector3(flat.x, flat.y, 0.0)
	return here.distance_to(origin) <= float(entry["range"])


# --- Replication driver -----------------------------------------------------

## Registers an object to be driven by the shared replication loop. It must
## implement `_mpf_replicate(index: int)` and may implement
## `_mpf_peer_ready(peer: MpfPeer)`.
##
## Components use this instead of connecting to the tick and peer signals
## individually: a world with a thousand replicated entities would otherwise
## fire a thousand signal emissions per tick, which is pure dispatch overhead.
## [param net_id] lets the relevancy sweep resynchronise this component when an
## entity comes back into range for a peer.
func register_replicator(target: Object, net_id: int = 0) -> void:
	if not _replicators.has(target):
		_replicators.append(target)
	if net_id != 0:
		var list: Array = _by_entity.get(net_id, [])
		if not list.has(target):
			list.append(target)
		_by_entity[net_id] = list


func unregister_replicator(target: Object, net_id: int = 0) -> void:
	_replicators.erase(target)
	if net_id != 0 and _by_entity.has(net_id):
		var list: Array = _by_entity[net_id]
		list.erase(target)
		if list.is_empty():
			_by_entity.erase(net_id)


## An entity that drifted out of a peer's range stopped sending to it, so when
## it comes back into range that peer is still holding whatever it last saw.
## Nothing else would ever correct it: an idle entity has no updates to send.
func _sweep_relevancy() -> void:
	if _relevancy.is_empty() or role == Role.NONE:
		return
	for id: int in multiplayer.get_peers():
		var seen: Dictionary = _relevant.get(id, {})
		for raw_id: Variant in _relevancy:
			var net_id := int(raw_id)
			var now_relevant := is_relevant_to(id, net_id)
			if now_relevant and not bool(seen.get(net_id, false)):
				_resync_entity(net_id, id)
			seen[net_id] = now_relevant
		_relevant[id] = seen


func _resync_entity(net_id: int, peer_id: int) -> void:
	for target: Object in _by_entity.get(net_id, []) as Array:
		if is_instance_valid(target) and target.has_method(&"_mpf_resync"):
			target.call(&"_mpf_resync", peer_id)


# --- Internals --------------------------------------------------------------

func _register_internal_channels() -> void:
	var internal := {"internal": true, "requires_auth": true}
	register_channel(&"__hello", _rx_hello, {
		"internal": true, "requires_auth": false, "direction": "to_server",
		"rate": 2.0, "max_bytes": 512,
		"schema": {
			"name": {"type": TYPE_STRING, "max_length": 64},
			"?pid": {"type": TYPE_STRING, "max_length": 32},
			"?ver": {"type": TYPE_STRING, "max_length": 32},
			"?pw": {"type": TYPE_STRING, "max_length": 128},
			"?tok": {"type": TYPE_STRING, "max_length": 64},
		},
	})
	register_channel(&"__welcome", _rx_welcome, MpfUtil.deep_merge(internal, {"direction": "to_clients", "max_bytes": 65536}))
	register_channel(&"__join", _rx_join, MpfUtil.deep_merge(internal, {"direction": "to_clients"}))
	register_channel(&"__leave", _rx_leave, MpfUtil.deep_merge(internal, {"direction": "to_clients"}))
	register_channel(&"__kick", _rx_kick, MpfUtil.deep_merge(internal, {"direction": "to_clients", "requires_auth": false}))
	# Both directions: the server pings clients too, so peer round-trip time is
	# measured rather than taken on trust from the client that reports it.
	register_channel(&"__ping", _rx_ping, MpfUtil.deep_merge(internal, {"reliable": false, "rate": 6.0}))
	register_channel(&"__pong", _rx_pong, MpfUtil.deep_merge(internal, {"reliable": false, "rate": 6.0}))
	register_channel(&"__meta", _rx_meta, MpfUtil.deep_merge(internal, {"direction": "to_server", "rate": 4.0, "max_bytes": 2048}))
	register_channel(&"__meta_set", _rx_meta_set, MpfUtil.deep_merge(internal, {"direction": "to_clients"}))
	# Batch channels bound themselves by entry count rather than byte size:
	# these are the hottest channels in the game, and re-serialising every
	# packet just to measure it is the wrong place to spend CPU.
	register_channel(&"__state", _rx_state_batch, MpfUtil.deep_merge(internal, {"rate": 120.0, "max_bytes": 0, "max_entries": 512}))
	register_channel(&"__tf", _rx_transform_batch, MpfUtil.deep_merge(internal, {"reliable": false, "rate": 120.0, "max_bytes": 0, "max_entries": 512}))
	register_channel(&"__scene", _rx_scene, MpfUtil.deep_merge(internal, {"direction": "to_clients"}))
	register_channel(&"__ready", _rx_ready, MpfUtil.deep_merge(internal, {"direction": "to_server", "rate": 2.0}))
	register_channel(&"__act", _rx_action, MpfUtil.deep_merge(internal, {"direction": "to_server", "rate": 30.0, "max_bytes": 4096}))
	register_channel(&"__actc", _rx_action, MpfUtil.deep_merge(internal, {"direction": "to_clients", "rate": 120.0, "max_bytes": 4096}))


func _make_transport(name: String, target: Variant) -> MpfTransport:
	var choice := name
	if choice == "auto":
		choice = _auto_transport(target)
	var made: MpfTransport = null
	match choice:
		"offline":
			made = MpfOfflineTransport.new()
		"steam":
			made = MpfSteamTransport.new()
		_:
			made = MpfEnetTransport.new()
	if not made.is_available():
		MpfLog.warn("net", "Transport unavailable, falling back to ENet", {"wanted": choice})
		made = MpfEnetTransport.new()
	made.failed.connect(func(reason: String) -> void: _last_error = reason)
	return made


static func _auto_transport(target: Variant) -> String:
	if typeof(target) == TYPE_STRING and (String(target).contains(".") or String(target).contains(":")):
		return "enet"
	if MpfSteamTransport.enabled() and MpfSteam.is_available() and MpfSteam.has_peer_class():
		return "steam"
	return "enet"


func _connect(target: Variant) -> bool:
	transport = _make_transport(String(config["transport"]), target)
	if transport == null:
		return _start_failed("no usable transport")
	var peer := transport.create_client(target, config)
	if peer == null:
		return _start_failed(transport.last_error)
	multiplayer.multiplayer_peer = peer
	role = Role.CLIENT
	time.reset()
	_set_status(Status.CONNECTING)
	MpfLog.info("net", "Connecting", {"target": transport.describe(target)})
	return true


func _start_failed(reason: String) -> bool:
	_last_error = reason
	role = Role.NONE
	transport = null
	_set_status(Status.FAILED)
	MpfLog.error("net", "Could not start session", {"reason": reason})
	connection_failed.emit.call_deferred(reason)
	return false


func _set_status(value: Status) -> void:
	if status == value:
		return
	status = value
	if value == Status.CONNECTING:
		_connect_deadline = Time.get_ticks_msec() + int(float(config.get("connect_timeout", 15.0)) * 1000.0)
	else:
		_connect_deadline = 0
	status_changed.emit(int(value))


func _local_peer(id: int) -> MpfPeer:
	var made := MpfPeer.new()
	made.id = id
	made.display_name = local_name
	made.platform_id = str(MpfSteam.steam_id()) if MpfSteam.is_ready() else ""
	made.is_local = true
	made.is_server = id == SERVER_ID
	made.joined_at_ms = Time.get_ticks_msec()
	# The host is a player too, and must file its save under the same identity
	# it would use as a client. Without this, hosting and joining give one
	# person two different saves.
	var token := local_identity_token()
	if token == "":
		token = MpfUtil.short_id(24)
		_store_identity_token(token)
	made.storage_key = MpfPeer.storage_key_for(made.platform_id, token, made.display_name)
	return made


func _bootstrap_from_cli() -> void:
	var args := MpfUtil.cli_args()
	if not (args.has("server") or args.has("dedicated")):
		return
	host_dedicated(int(str(args.get("port", DEFAULT_PORT))), {
		"max_players": int(str(args.get("max-players", 16))),
		"transport": str(args.get("transport", "enet")),
		"lobby_name": str(args.get("name", "Dedicated Server")),
		"password": str(args.get("password", "")),
	})


# --- Multiplayer events -----------------------------------------------------

func _on_peer_connected(id: int) -> void:
	if not is_server():
		return
	_pending[id] = Time.get_ticks_msec() + int(float(config.get("auth_timeout", 10.0)) * 1000.0)


func _on_peer_disconnected(id: int) -> void:
	_pending.erase(id)
	_limiters.erase(id)
	_budgets.erase(id)
	_relevant.erase(id)
	var gone: MpfPeer = _peers.get(id)
	if gone == null:
		return
	_peers.erase(id)
	if is_server():
		_reserve_slot(gone)
		send_to_all(&"__leave", {"id": id, "reason": "disconnected"}, [local_id()])
		lobbies.update_advertisement(player_count())
	peer_left.emit(gone, "disconnected")


func _on_connected_to_server() -> void:
	send_to_server(&"__hello", {
		"name": local_name,
		"pid": str(MpfSteam.steam_id()) if MpfSteam.is_ready() else "",
		"ver": String(config.get("game_version", "")),
		"pw": _hash_password(String(config.get("password", ""))),
		"tok": local_identity_token(),
	})


func _on_connection_failed() -> void:
	_last_error = "could not reach the server"
	role = Role.NONE
	_set_status(Status.FAILED)
	connection_failed.emit(_last_error)


func _on_server_disconnected() -> void:
	leave("server closed")


func _on_lobby_resolved(_lobby_id: String, target: Variant) -> void:
	if role == Role.NONE and status == Status.CONNECTING:
		_connect(target)


func _on_lobby_failed(reason: String) -> void:
	_start_failed(reason)


func _on_tick(_delta: float, index: int) -> void:
	_drive_replicators(index)
	# A few times a second is plenty: this only catches range transitions, and
	# it is O(peers x range-limited entities).
	if is_server() and index % 10 == 0:
		_sweep_relevancy()
	for channel_name: StringName in _batches.keys():
		var batch: Dictionary = _batches[channel_name]
		if batch.is_empty():
			continue
		if is_server():
			_broadcast_batch(channel_name, batch)
		else:
			send_to_server(channel_name, batch)
	_batches.clear()
	for peer_id: int in _targeted.keys():
		var channels: Dictionary = _targeted[peer_id]
		for channel_name: StringName in channels:
			var batch: Dictionary = channels[channel_name]
			if not batch.is_empty():
				send_to(channel_name, peer_id, batch)
	_targeted.clear()


func _drive_replicators(index: int) -> void:
	var dead := false
	for target: Object in _replicators:
		if is_instance_valid(target):
			target.call(&"_mpf_replicate", index)
		else:
			dead = true
	if dead:
		_replicators = _replicators.filter(func(t: Object) -> bool: return is_instance_valid(t))


## Sends a batch to every client, dropping entries a peer cannot perceive.
## Falls back to a single broadcast when nothing in the batch is range-limited,
## so games that do not use relevancy pay nothing for it.
func _broadcast_batch(channel_name: StringName, batch: Dictionary) -> void:
	var channel: MpfChannel = _channels.get(channel_name)
	if channel == null or role == Role.NONE:
		send_to_all(channel_name, batch, [local_id()])
		return
	if not _batch_has_relevancy(batch):
		send_to_all(channel_name, batch, [local_id()])
		return
	_invoke(channel, local_id(), batch)
	for id: int in multiplayer.get_peers():
		var visible := {}
		for raw_id: Variant in batch:
			if is_relevant_to(id, int(raw_id)):
				visible[raw_id] = batch[raw_id]
		if not visible.is_empty():
			_send_rpc(id, channel, visible)


func _batch_has_relevancy(batch: Dictionary) -> bool:
	if _relevancy.is_empty():
		return false
	for raw_id: Variant in batch:
		if _relevancy.has(int(raw_id)):
			return true
	return false


func _expire_pending() -> void:
	if _pending.is_empty():
		return
	var now := Time.get_ticks_msec()
	for id: int in _pending.keys():
		if now > int(_pending[id]):
			_pending.erase(id)
			MpfLog.warn("net", "Handshake timed out", {"peer": id})
			kick(id, "handshake timed out")


## Clients ping once a second, so silence means the peer is gone even if the
## transport has not worked that out yet. Without this a player who force-quits
## or loses their connection keeps a slot, a scoreboard row and a spawned
## entity until ENet's much longer timeout expires.
func _expire_silent() -> void:
	var limit := float(config.get("peer_timeout", 12.0))
	if limit <= 0.0:
		return
	var cutoff := Time.get_ticks_msec() - int(limit * 1000.0)
	for existing: MpfPeer in peers():
		if existing.id != local_id() and existing.last_seen_ms < cutoff:
			MpfLog.warn("net", "Peer timed out", {"peer": existing.id, "name": existing.display_name})
			_drop_peer(existing.id, "timed out")


## Hard disconnect for a peer that is already unreachable. Unlike [method kick]
## there is no grace period, and the local roster is updated immediately rather
## than waiting for a transport signal that may never arrive.
func _drop_peer(peer_id: int, reason: String) -> void:
	send_to(&"__kick", peer_id, {"reason": reason})
	if multiplayer.multiplayer_peer != null and role == Role.SERVER:
		multiplayer.multiplayer_peer.disconnect_peer(peer_id, true)
	_on_peer_disconnected(peer_id)


func _disconnect_later(peer_id: int) -> void:
	await get_tree().create_timer(0.25).timeout
	if multiplayer.multiplayer_peer != null and role == Role.SERVER:
		multiplayer.multiplayer_peer.disconnect_peer(peer_id)


# --- Message routing --------------------------------------------------------

@rpc("any_peer", "call_remote", "reliable", 0)
func _mpf_rx_reliable(channel_name: StringName, payload: Variant) -> void:
	_receive(multiplayer.get_remote_sender_id(), channel_name, payload)


@rpc("any_peer", "call_remote", "unreliable", 1)
func _mpf_rx_unreliable(channel_name: StringName, payload: Variant) -> void:
	_receive(multiplayer.get_remote_sender_id(), channel_name, payload)


@rpc("any_peer", "call_remote", "unreliable_ordered", 2)
func _mpf_rx_ordered(channel_name: StringName, payload: Variant) -> void:
	_receive(multiplayer.get_remote_sender_id(), channel_name, payload)


func _send_rpc(target: int, channel: MpfChannel, payload: Variant) -> void:
	if role == Role.NONE or multiplayer.multiplayer_peer == null:
		return
	# Replying to a peer that left between its message arriving and the reply
	# going out is routine, not exceptional - a queued handler, a deferred call
	# or a slow frame is enough. Without this the engine raises a hard error.
	if target != SERVER_ID and not multiplayer.get_peers().has(target):
		return
	if channel.reliable:
		rpc_id(target, &"_mpf_rx_reliable", channel.name, payload)
	elif channel.ordered:
		rpc_id(target, &"_mpf_rx_ordered", channel.name, payload)
	else:
		rpc_id(target, &"_mpf_rx_unreliable", channel.name, payload)


## Every inbound remote message funnels through here, so direction, auth,
## rate and schema are enforced in one place rather than per handler.
func _receive(sender: int, channel_name: StringName, payload: Variant) -> void:
	var channel: MpfChannel = _channels.get(channel_name)
	if channel == null:
		MpfLog.debug("net", "Unknown channel", {"channel": String(channel_name), "from": sender})
		return
	if not channel.accepts_from(sender == SERVER_ID):
		MpfLog.warn("net", "Rejected wrong-direction message", {"channel": String(channel_name), "from": sender})
		return
	if channel.requires_auth and not _authenticated(sender):
		MpfLog.warn("net", "Rejected unauthenticated message", {"channel": String(channel_name), "from": sender})
		return
	# Per-channel limits alone leave a hole: a client can sit at the limit on
	# every channel at once. The budget caps a peer's total traffic, which is
	# what protects a player hosting for friends from being flooded.
	if sender != local_id() and not _budget_for(sender).allow(&"total", _message_budget(), _message_budget()):
		MpfLog.warn("net", "Peer over message budget", {"from": sender})
		return
	if not _limiter_for(sender).allow(channel_name, channel.rate, channel.burst):
		MpfLog.warn("net", "Rate limited", {"channel": String(channel_name), "from": sender})
		return
	if channel.max_entries > 0 and not _within_entry_cap(payload, channel.max_entries):
		MpfLog.warn("net", "Too many entries", {"channel": String(channel_name), "from": sender})
		return
	if channel.max_bytes > 0 and var_to_bytes(payload).size() > channel.max_bytes:
		MpfLog.warn("net", "Payload too large", {"channel": String(channel_name), "from": sender})
		return
	if not channel.schema.is_empty():
		var reason := MpfSchema.validate(payload, channel.schema)
		if reason != "":
			MpfLog.warn("net", "Schema rejected payload", {"channel": String(channel_name), "from": sender, "reason": reason})
			return
	if _condition(channel, sender, payload):
		return
	_invoke(channel, sender, payload)


## Returns true when the message was dropped or deferred by the conditioner.
func _condition(channel: MpfChannel, sender: int, payload: Variant) -> bool:
	if sender == local_id():
		return false
	if simulate_loss > 0.0 and not channel.reliable and randf() < simulate_loss:
		return true
	if simulate_latency_ms <= 0.0 and simulate_jitter_ms <= 0.0:
		return false
	var delay := simulate_latency_ms + randf_range(-simulate_jitter_ms, simulate_jitter_ms)
	_delayed.append({
		"at": Time.get_ticks_msec() + maxf(0.0, delay),
		"channel": channel,
		"sender": sender,
		"payload": payload,
	})
	return true


func _flush_delayed() -> void:
	if _delayed.is_empty():
		return
	var now := float(Time.get_ticks_msec())
	var pending := []
	for entry: Dictionary in _delayed:
		if float(entry["at"]) <= now:
			_invoke(entry["channel"], int(entry["sender"]), entry["payload"])
		else:
			pending.append(entry)
	_delayed = pending


func _invoke(channel: MpfChannel, sender: int, payload: Variant) -> void:
	if channel.handler.is_valid():
		channel.handler.call(sender, payload)


## One bucket set per peer, so a disconnect can drop them all at once. Keying a
## single limiter by (peer, channel) pairs would leak a bucket per channel for
## every peer that ever connected.
## O(1) size check, unlike [method @GlobalScope.var_to_bytes] which has to walk
## and re-serialise the whole payload.
static func _within_entry_cap(payload: Variant, limit: int) -> bool:
	match typeof(payload):
		TYPE_DICTIONARY:
			return (payload as Dictionary).size() <= limit
		TYPE_ARRAY:
			return (payload as Array).size() <= limit
	return true


func _message_budget() -> float:
	return float(config.get("peer_message_budget", 240.0))


func _budget_for(sender: int) -> MpfRate:
	var found: MpfRate = _budgets.get(sender)
	if found == null:
		found = MpfRate.new()
		_budgets[sender] = found
	return found


func _limiter_for(sender: int) -> MpfRate:
	var found: MpfRate = _limiters.get(sender)
	if found == null:
		found = MpfRate.new()
		_limiters[sender] = found
	return found


func _authenticated(sender: int) -> bool:
	if sender == SERVER_ID or not is_server():
		return true
	return _peers.has(sender)


func _unknown(channel_name: StringName) -> void:
	MpfLog.error("net", "Send on unregistered channel", {"channel": String(channel_name)})


# --- Handshake handlers -----------------------------------------------------

func _rx_hello(sender: int, payload: Dictionary) -> void:
	if not is_server() or sender == local_id():
		return
	if not _pending.has(sender):
		return
	_pending.erase(sender)
	var expected_version := String(config.get("game_version", ""))
	if expected_version != "" and String(payload.get("ver", "")) != expected_version:
		kick(sender, "version mismatch (server runs %s)" % expected_version)
		return
	var password := String(config.get("password", ""))
	if password != "" and String(payload.get("pw", "")) != _hash_password(password):
		kick(sender, "wrong password")
		return
	var display_name := _clean_name(String(payload.get("name", "Player")))
	# Identity is decided here, by the server. A peer that picks its own
	# storage key can load anyone else's save simply by claiming their name.
	var platform_id := _verified_platform_id(sender, String(payload.get("pid", "")))
	var token := String(payload.get("tok", ""))
	if platform_id == "" and not _valid_token(token):
		token = MpfUtil.short_id(24)
	var storage_key := MpfPeer.storage_key_for(platform_id, token, display_name)

	var claimed := _claim_slot(storage_key)
	if claimed.is_empty() and player_count() + reserved_count() >= max_players():
		kick(sender, "server is full")
		return
	var joined := MpfPeer.new()
	joined.id = sender
	joined.display_name = display_name
	joined.platform_id = platform_id
	joined.storage_key = storage_key
	joined.authenticated = true
	if not claimed.is_empty():
		joined.meta = claimed.get("meta", {}) as Dictionary
		joined.resumed = true
	joined.joined_at_ms = Time.get_ticks_msec()
	joined.last_seen_ms = joined.joined_at_ms
	_peers[sender] = joined

	var roster: Array = []
	for existing: MpfPeer in peers():
		roster.append(existing.to_dict())
	send_to(&"__welcome", sender, {
		"you": sender,
		"peers": roster,
		"server_ms": MpfNetTime.local_ms(),
		"scene": current_scene,
		"tok": token,
	})
	send_to_all(&"__join", joined.to_dict(), [local_id(), sender])
	lobbies.update_advertisement(player_count())
	MpfLog.info("net", "Peer joined", {"peer": sender, "name": joined.display_name, "resumed": joined.resumed})
	peer_joined.emit(joined)
	if joined.resumed:
		peer_resumed.emit(joined, int(claimed.get("peer_id", 0)))


func _rx_welcome(_sender: int, payload: Dictionary) -> void:
	if is_server():
		return
	var my_id := int(payload.get("you", 0))
	_peers.clear()
	for raw: Variant in payload.get("peers", []) as Array:
		var made := MpfPeer.from_dict(raw as Dictionary)
		made.authenticated = true
		made.is_local = made.id == my_id
		_peers[made.id] = made
	_store_identity_token(String(payload.get("tok", "")))
	time.bootstrap(float(payload.get("server_ms", 0.0)))
	_set_status(Status.ONLINE)
	MpfLog.info("net", "Joined session", {"id": my_id, "players": player_count()})
	session_started.emit(int(role))
	for existing: MpfPeer in peers():
		peer_joined.emit(existing)
	var scene := String(payload.get("scene", ""))
	if scene != "" and scene != _local_scene_path():
		_apply_scene(scene)
	else:
		current_scene = scene
		send_to_server(&"__ready", {"scene": scene})


func _rx_join(_sender: int, payload: Dictionary) -> void:
	if is_server():
		return
	var made := MpfPeer.from_dict(payload)
	made.authenticated = true
	_peers[made.id] = made
	peer_joined.emit(made)


func _rx_leave(_sender: int, payload: Dictionary) -> void:
	if is_server():
		return
	var id := int(payload.get("id", 0))
	var gone: MpfPeer = _peers.get(id)
	if gone == null:
		return
	_peers.erase(id)
	peer_left.emit(gone, String(payload.get("reason", "left")))


func _rx_kick(_sender: int, payload: Dictionary) -> void:
	var reason := String(payload.get("reason", "kicked"))
	_last_error = reason
	MpfLog.warn("net", "Kicked", {"reason": reason})
	kicked.emit(reason)
	leave(reason)


## Server only. Moves every peer to [param path] and marks them un-ready until
## each confirms it finished loading.
func change_scene(path: String) -> void:
	if not is_server():
		MpfLog.warn("net", "Only the server may change the scene")
		return
	current_scene = path
	for existing: MpfPeer in peers():
		existing.scene_ready = existing.id == local_id()
	send_to_all(&"__scene", {"path": path}, [local_id()])
	_apply_scene(path)


# --- Reconnect grace --------------------------------------------------------

## Slots currently held open for peers that dropped and may come back.
func reserved_count() -> int:
	_expire_reservations()
	return _reserved.size()


## Drops a held slot, for example when a player quits deliberately rather than
## losing their connection.
func release_reservation(storage_key: String) -> void:
	_reserved.erase(storage_key)


## Holds a peer's slot and game data after a disconnect. Losing your connection
## for thirty seconds in a co-op session should not cost you your place, your
## team or your loadout.
func _reserve_slot(gone: MpfPeer) -> void:
	var grace := float(config.get("reconnect_grace", 0.0))
	if grace <= 0.0:
		return
	var key := gone.storage_key
	_reserved[key] = {
		"meta": gone.meta.duplicate(true),
		"peer_id": gone.id,
		"expires": Time.get_ticks_msec() + int(grace * 1000.0),
	}
	MpfLog.info("net", "Holding slot for reconnect", {"key": key, "seconds": grace})


## Returns the held entry and consumes it, or an empty dictionary.
func _claim_slot(key: String) -> Dictionary:
	_expire_reservations()
	if not _reserved.has(key):
		return {}
	var entry: Dictionary = _reserved[key]
	_reserved.erase(key)
	return entry


func _expire_reservations() -> void:
	var now := Time.get_ticks_msec()
	for key: Variant in _reserved.keys():
		if now > int((_reserved[key] as Dictionary)["expires"]):
			_reserved.erase(key)


## Peers that have finished loading and can safely be spawned into.
func ready_peers() -> Array[MpfPeer]:
	var out: Array[MpfPeer] = []
	for existing: MpfPeer in peers():
		if existing.scene_ready:
			out.append(existing)
	return out


func _rx_scene(_sender: int, payload: Dictionary) -> void:
	if not is_server():
		_apply_scene(String(payload.get("path", "")))


func _rx_ready(sender: int, payload: Dictionary) -> void:
	if not is_server():
		return
	var waiting: MpfPeer = _peers.get(sender)
	if waiting == null or waiting.scene_ready:
		return
	# Ignore a peer reporting ready for a scene we have already moved on from.
	if current_scene != "" and String(payload.get("scene", "")) != current_scene:
		return
	waiting.scene_ready = true
	MpfLog.debug("net", "Peer ready", {"peer": sender})
	peer_ready.emit(waiting)


func _apply_scene(path: String) -> void:
	if path == "":
		return
	current_scene = path
	scene_changing.emit(path)
	# The old tree is about to be freed, so drop every handle into it before
	# the registries start handing out dangling nodes.
	_entities.clear()
	_receivers.clear()
	_player_nodes.clear()
	_relevancy.clear()
	_replicators.clear()
	_batches.clear()
	_targeted.clear()
	var result := get_tree().change_scene_to_file(path)
	if result != OK:
		MpfLog.error("net", "Could not change scene", {"path": path, "error": error_string(result)})
		return
	# change_scene_to_file is deferred; wait for the swap before announcing.
	await get_tree().process_frame
	await get_tree().process_frame
	scene_changed.emit(path)
	if is_client():
		send_to_server(&"__ready", {"scene": path})


func _local_scene_path() -> String:
	var scene := get_tree().current_scene
	return scene.scene_file_path if scene != null else ""


## Echoes the sender's stamp straight back, so only the sender ever interprets
## its own clock. Both sides use the same handler.
func _rx_ping(sender: int, payload: Dictionary) -> void:
	var from: MpfPeer = _peers.get(sender)
	if from != null:
		from.last_seen_ms = Time.get_ticks_msec()
	send_to(&"__pong", sender, {"t": payload.get("t", 0.0), "s": MpfNetTime.local_ms()})


func _rx_pong(sender: int, payload: Dictionary) -> void:
	var sent := float(payload.get("t", 0.0))
	if is_server():
		# The server owns the clock, so it only wants the round trip.
		var from: MpfPeer = _peers.get(sender)
		if from != null:
			from.rtt_ms = MpfNetTime.local_ms() - sent
			from.last_seen_ms = Time.get_ticks_msec()
		return
	time.submit(sent, float(payload.get("s", 0.0)), MpfNetTime.local_ms())


func _rx_meta(sender: int, payload: Dictionary) -> void:
	if not is_server():
		return
	var target: MpfPeer = _peers.get(sender)
	if target == null:
		return
	if payload.has("name"):
		target.display_name = _clean_name(String(payload["name"]))
	if payload.has("key"):
		target.meta[StringName(payload["key"])] = payload.get("value")
	send_to_all(&"__meta_set", {"id": sender, "name": target.display_name, "meta": target.meta}, [local_id()])
	peer_meta_changed.emit(target)


func _rx_meta_set(_sender: int, payload: Dictionary) -> void:
	if is_server():
		return
	var target: MpfPeer = _peers.get(int(payload.get("id", 0)))
	if target == null:
		return
	target.display_name = String(payload.get("name", target.display_name))
	target.meta = payload.get("meta", {}) as Dictionary
	peer_meta_changed.emit(target)


func _rx_state_batch(sender: int, payload: Dictionary) -> void:
	_route_entity_batch(&"__state", sender, payload)


func _rx_transform_batch(sender: int, payload: Dictionary) -> void:
	_route_entity_batch(&"__tf", sender, payload)


## Actions are never relayed verbatim - the server decides what to confirm and
## broadcasts that itself.
func _rx_action(sender: int, payload: Dictionary) -> void:
	for raw_id: Variant in payload:
		var map: Dictionary = _receivers.get(int(raw_id), {})
		var receiver: Callable = map.get(&"__act", Callable())
		if receiver.is_valid():
			receiver.call(sender, payload[raw_id])


## Fans a batch out to per-entity receivers. The receiver decides whether the
## sender was allowed to make the change; the server then relays only what was
## accepted, so a client cannot use the relay to move entities it does not own.
func _route_entity_batch(channel_name: StringName, sender: int, payload: Dictionary) -> void:
	var accepted := {}
	for raw_id: Variant in payload:
		var map: Dictionary = _receivers.get(int(raw_id), {})
		var receiver: Callable = map.get(channel_name, Callable())
		if not receiver.is_valid():
			continue
		if bool(receiver.call(sender, payload[raw_id])):
			accepted[raw_id] = payload[raw_id]
	if is_server() and sender != local_id() and not accepted.is_empty():
		send_to_all(channel_name, accepted, [local_id(), sender])


## A platform id is only believed when something other than the peer vouches
## for it. Over Steam the transport establishes it; over raw ENet nothing does,
## so a claimed id is discarded unless the game explicitly opts in.
func _verified_platform_id(sender: int, claimed: String) -> String:
	# Ask the transport who this peer actually is. Over Steam the connection
	# itself establishes identity, so a mismatch means the peer lied.
	if transport != null and transport.has_method(&"peer_steam_id"):
		var actual := int(transport.call(&"peer_steam_id", sender))
		if actual != 0:
			if claimed != "" and claimed != str(actual):
				MpfLog.warn("net", "Peer claimed an identity that is not its own", {
					"peer": sender, "claimed": claimed, "actual": actual,
				})
			return str(actual)
	if claimed == "":
		return ""
	if bool(config.get("trust_client_identity", false)):
		return claimed
	MpfLog.debug("net", "Ignoring unverified platform id", {"peer": sender})
	return ""


## Tokens are server-issued, so anything malformed was not issued by us.
static func _valid_token(token: String) -> bool:
	if token.length() < 16 or token.length() > 64:
		return false
	for i: int in token.length():
		if not (token[i].is_valid_identifier() or token[i].is_valid_int()):
			return false
	return true


## The secret this machine presents to prove it is the same player as last
## time. Stored locally; a peer with no token is issued one on first join.
func local_identity_token() -> String:
	var save := MpfRuntime.save()
	if save == null:
		return ""
	return String(save.open("mpf_identity").get_value("token", ""))


func _store_identity_token(token: String) -> void:
	if token == "" or not _valid_token(token):
		return
	var save := MpfRuntime.save()
	if save == null:
		return
	var profile: MpfProfile = save.open("mpf_identity")
	if String(profile.get_value("token", "")) != token:
		profile.set_value("token", token)
		profile.save()


static func _clean_name(value: String) -> String:
	var cleaned := value.strip_edges().replace("\n", " ").replace("\r", "")
	if cleaned.length() > MAX_NAME_LENGTH:
		cleaned = cleaned.substr(0, MAX_NAME_LENGTH)
	return cleaned if cleaned != "" else "Player"


## Keeps the plaintext password off the wire. This is a lobby gate, not a
## security boundary - see docs/networking.md.
static func _hash_password(value: String) -> String:
	return "" if value == "" else value.sha256_text()
