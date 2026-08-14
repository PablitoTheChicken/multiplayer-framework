class_name MpfNetWorld
extends Node
## Spawn root for networked entities. Put one in your gameplay scene.
##
## The server calls [method spawn]; every client receives the same entity with
## the same name, net id and owner, and a peer that joins later is caught up
## with everything already spawned.
##
## Spawning is replicated over MPF's own channel rather than through
## [MultiplayerSpawner]. That keeps it inside the validated message funnel,
## makes late-join catch-up explicit, and avoids depending on engine behaviour
## that proved not to reach every peer in a three-peer test.

signal entity_spawned(node: Node, key: StringName)
signal entity_despawned(node: Node)

## Scenes this world can spawn, addressed by key over the wire.
@export var scenes: Dictionary[StringName, PackedScene] = {}
## Where spawned entities are parented. Defaults to this node.
@export var spawn_parent: NodePath

var _parent: Node = null
var _sequence: int = 0
var _spawned: Array[Node] = []
## Replayed verbatim to a peer that joins later, keyed by instance id so a
## record can be dropped when its node dies by any route.
var _records: Dictionary = {}
var _net: Node = null


func _ready() -> void:
	_parent = get_node_or_null(spawn_parent) if not spawn_parent.is_empty() else self
	if _parent == null:
		_parent = self
	_net = MpfRuntime.net()
	if _net == null:
		return
	_net.world = self
	_net.session_ended.connect(_on_session_ended)
	_net.peer_ready.connect(_on_peer_ready)
	_net.register_channel(&"__spawn", _rx_spawn, {
		"internal": true, "direction": "to_clients", "max_bytes": 262144, "rate": 60.0,
	})
	_net.register_channel(&"__despawn", _rx_despawn, {
		"internal": true, "direction": "to_clients", "rate": 60.0,
	})


func _exit_tree() -> void:
	if _net != null and _net.world == self:
		_net.world = null


func register_scene(key: StringName, scene: PackedScene) -> void:
	scenes[key] = scene


## Server only. Spawns [param key] on every peer and returns the local node.
## [param props] are applied to matching exported properties of the root before
## it enters the tree, so use them for anything that must be right immediately.
## [param authority] overrides the scene's authored [MpfNetIdentity.authority];
## leave it at -1 to keep it. Passing an owner without owner authority is a
## common mistake - the owner is recorded but grants nothing, so its writes are
## silently refused.
func spawn(key: StringName, props: Dictionary = {}, owner_peer_id: int = 1, authority: int = -1) -> Node:
	if not MpfRuntime.is_server():
		MpfLog.warn("net", "Only the server may spawn", {"key": String(key)})
		return null
	if not scenes.has(key):
		MpfLog.error("net", "Unknown spawn key", {"key": String(key)})
		return null
	_sequence += 1
	var record := {
		"k": String(key),
		"n": "%s#%d" % [key, _sequence],
		"i": _net.allocate_net_id() if _net != null else _sequence,
		"o": owner_peer_id,
		"a": authority,
		"p": props,
	}
	var node := _spawn_from_data(record)
	if node == null:
		return null
	_records[node.get_instance_id()] = record
	if _net != null:
		_net.send_to_all(&"__spawn", {"e": [record]}, [_net.local_id()])
	return node


## Server only. Removes the entity everywhere.
func despawn(node: Node) -> void:
	if not MpfRuntime.is_server() or not is_instance_valid(node):
		return
	var entity_name := String(node.name)
	_forget(node)
	node.queue_free()
	if _net != null:
		_net.send_to_all(&"__despawn", {"n": entity_name}, [_net.local_id()])


## Every entity this world spawned that is still alive.
func entities() -> Array[Node]:
	var out: Array[Node] = []
	for node: Node in _spawned:
		if is_instance_valid(node):
			out.append(node)
	return out


## Frees every entity this world spawned. Spawned nodes are otherwise orphaned
## on a client that disconnects, and reconnecting would stack a second set on
## top of the first.
func clear_entities() -> void:
	for node: Node in _spawned:
		if not is_instance_valid(node):
			continue
		# Detach before freeing so the name is released immediately; queue_free
		# alone holds it until the end of the frame, which can force a rename on
		# an entity respawning with the same name.
		if node.get_parent() != null:
			node.get_parent().remove_child(node)
		node.queue_free()
	_spawned.clear()
	if MpfRuntime.is_server():
		_records.clear()


# --- Persistence ------------------------------------------------------------

## Server only. Snapshot of every entity whose identity is marked persistent.
##
## Spawned entities record the scene to rebuild them from; scene-placed ones
## record only their replicated state, because the node itself comes back with
## the level. Transforms are stored as plain float arrays so the result stays
## JSON-safe.
func capture() -> Dictionary:
	var spawned: Array = []
	var placed: Dictionary = {}
	if not MpfRuntime.is_server():
		MpfLog.warn("net", "Only the server may capture the world")
		return {"spawned": spawned, "placed": placed}

	_prune()
	for node: Node in entities():
		var identity := MpfNetIdentity.of(node)
		if identity == null or not identity.persistent:
			continue
		spawned.append({
			"k": String(node.get_meta(&"mpf_spawn_key", "")),
			"o": identity.owner_peer_id,
			"t": _pack_transform(node),
			"s": _capture_state(node),
		})

	if _net != null:
		for raw_id: Variant in _net.entity_ids():
			var node: Node = _net.find_entity(int(raw_id))
			if node == null or _spawned.has(node):
				continue
			var identity := MpfNetIdentity.of(node)
			if identity == null or not identity.persistent:
				continue
			placed[str(raw_id)] = _capture_state(node)

	return {"spawned": spawned, "placed": placed}


## Server only. Rebuilds spawned entities and restores state onto scene-placed
## ones. Existing spawned entities are cleared first, so restoring twice gives
## the same result as restoring once.
func restore(snapshot: Dictionary) -> int:
	if not MpfRuntime.is_server():
		MpfLog.warn("net", "Only the server may restore the world")
		return 0
	clear_entities()
	var restored := 0
	for raw: Variant in snapshot.get("spawned", []) as Array:
		var entry: Dictionary = raw
		var key := StringName(entry.get("k", ""))
		if not scenes.has(key):
			MpfLog.warn("net", "Save references an unknown scene", {"key": String(key)})
			continue
		var node := spawn(key, {}, int(entry.get("o", 1)))
		if node == null:
			continue
		_unpack_transform(node, entry.get("t", []) as Array)
		_restore_state(node, entry.get("s", {}) as Dictionary)
		restored += 1

	if _net != null:
		var placed: Dictionary = snapshot.get("placed", {}) as Dictionary
		for raw_id: Variant in placed:
			var node: Node = _net.find_entity(int(str(raw_id)))
			if node != null:
				_restore_state(node, placed[raw_id] as Dictionary)
				restored += 1
	MpfLog.info("net", "World restored", {"entities": restored})
	return restored


# --- Replication ------------------------------------------------------------

## A peer only becomes able to receive spawns once it has finished loading, so
## the catch-up is sent here rather than on connect.
func _on_peer_ready(peer: MpfPeer) -> void:
	if not MpfRuntime.is_server() or _net == null:
		return
	_prune()
	if peer.id == _net.local_id() or _records.is_empty():
		return
	MpfLog.debug("net", "Sending spawn catch-up", {"peer": peer.id, "count": _records.size()})
	_net.send_to(&"__spawn", peer.id, {"e": _records.values()})


func _on_session_ended(_reason: String) -> void:
	clear_entities()


func _rx_spawn(_sender: int, payload: Dictionary) -> void:
	if MpfRuntime.is_server():
		return
	MpfLog.info("net", "Received spawn batch", {"count": (payload.get("e", []) as Array).size()})
	for raw: Variant in payload.get("e", []) as Array:
		var record: Dictionary = raw
		# Catch-up batches repeat entities this peer may already have.
		if _parent.get_node_or_null(NodePath(String(record.get("n", "")))) != null:
			continue
		_spawn_from_data(record)


func _rx_despawn(_sender: int, payload: Dictionary) -> void:
	if MpfRuntime.is_server():
		return
	var node := _parent.get_node_or_null(NodePath(String(payload.get("n", ""))))
	if node != null:
		_forget(node)
		node.queue_free()


func _forget(node: Node) -> void:
	_spawned.erase(node)
	_records.erase(node.get_instance_id())
	entity_despawned.emit(node)


## Games free entities directly all the time; only despawn() goes through
## _forget. Without this sweep a freed node leaves its record behind and the
## next peer to join is sent a spawn for something that no longer exists.
func _prune() -> void:
	for id: Variant in _records.keys():
		if not is_instance_id_valid(int(id)):
			_records.erase(id)
	_spawned = _spawned.filter(func(node: Node) -> bool: return is_instance_valid(node))


func _spawn_from_data(record: Dictionary) -> Node:
	var key := StringName(record.get("k", ""))
	var scene: PackedScene = scenes.get(key)
	if scene == null:
		MpfLog.error("net", "Cannot spawn unknown key", {"key": String(key)})
		return null
	var node := scene.instantiate()
	node.name = String(record.get("n", String(key)))
	var identity := MpfNetIdentity.of(node)
	if identity != null:
		identity.net_id = int(record.get("i", 0))
		identity.owner_peer_id = int(record.get("o", 1))
		var authority := int(record.get("a", -1))
		if authority >= 0:
			identity.authority = authority as MpfNetIdentity.Authority
	var props: Dictionary = record.get("p", {}) as Dictionary
	# Remembered so a capture can name the scene to respawn from.
	node.set_meta(&"mpf_spawn_key", String(key))
	_apply_props(node, props)
	_parent.add_child(node)
	if node.has_method("_net_spawned"):
		node.call("_net_spawned", props)
	_spawned.append(node)
	entity_spawned.emit(node, key)
	return node


## Only writes properties the node actually declares, so a malformed spawn
## payload cannot poke at arbitrary internals.
static func _apply_props(node: Node, props: Dictionary) -> void:
	if props.is_empty():
		return
	var declared := {}
	for info: Dictionary in node.get_property_list():
		declared[String(info.get("name", ""))] = true
	for key: Variant in props:
		var property := String(key)
		if declared.has(property):
			node.set(property, props[key])


static func _capture_state(node: Node) -> Dictionary:
	var state := MpfUtil.find_child_of_type(node, MpfNetState) as MpfNetState
	return state.all() if state != null else {}


static func _restore_state(node: Node, values: Dictionary) -> void:
	var state := MpfUtil.find_child_of_type(node, MpfNetState) as MpfNetState
	if state == null:
		return
	for key: Variant in values:
		# define first, so restoring does not trip the undeclared-key warning
		# for an entity whose own _ready has not run yet.
		state.define(StringName(key), values[key])
		state.set_value(StringName(key), values[key])


static func _pack_transform(node: Node) -> Array:
	if node is Node3D:
		var n3 := node as Node3D
		return [n3.global_position.x, n3.global_position.y, n3.global_position.z,
			n3.global_rotation.x, n3.global_rotation.y, n3.global_rotation.z]
	if node is Node2D:
		var n2 := node as Node2D
		return [n2.global_position.x, n2.global_position.y, 0.0, 0.0, 0.0, n2.global_rotation]
	return []


static func _unpack_transform(node: Node, values: Array) -> void:
	if values.size() < 6:
		return
	if node is Node3D:
		var n3 := node as Node3D
		n3.global_position = Vector3(values[0], values[1], values[2])
		n3.global_rotation = Vector3(values[3], values[4], values[5])
	elif node is Node2D:
		var n2 := node as Node2D
		n2.global_position = Vector2(values[0], values[1])
		n2.global_rotation = float(values[5])
