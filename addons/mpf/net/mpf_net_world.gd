class_name MpfNetWorld
extends Node
## Spawn root for networked entities. Put one in your gameplay scene.
##
## The server calls [method spawn]; clients receive the same entity with the
## same name, net id and owner. Late joiners get everything already spawned.

signal entity_spawned(node: Node, key: StringName)
signal entity_despawned(node: Node)

## Scenes this world can spawn, addressed by key over the wire.
@export var scenes: Dictionary[StringName, PackedScene] = {}
## Where spawned entities are parented. Defaults to this node.
@export var spawn_parent: NodePath

var _spawner: MultiplayerSpawner = null
var _parent: Node = null
var _sequence: int = 0
var _spawned: Array[Node] = []


func _ready() -> void:
	_parent = get_node_or_null(spawn_parent) if not spawn_parent.is_empty() else self
	if _parent == null:
		_parent = self
	_spawner = MultiplayerSpawner.new()
	_spawner.name = "__spawner"
	add_child(_spawner)
	_spawner.spawn_path = _spawner.get_path_to(_parent)
	_spawner.spawn_function = _spawn_from_data
	_spawner.despawned.connect(func(node: Node) -> void: entity_despawned.emit(node))
	var net := MpfRuntime.net()
	if net != null:
		net.world = self
		net.session_ended.connect(_on_session_ended)


## Spawned nodes are despawned by the server freeing them, which a client that
## has just disconnected will never hear about. Without this they survive as
## orphans, and reconnecting stacks a second set of entities on top of them.
func _on_session_ended(_reason: String) -> void:
	clear_entities()


## Frees every entity this world spawned.
func clear_entities() -> void:
	for node: Node in _spawned:
		if not is_instance_valid(node):
			continue
		# Detach before freeing so the name is released immediately; queue_free
		# alone leaves it taken until the end of the frame, which can force a
		# rename on an entity respawning with the same name.
		if node.get_parent() != null:
			node.get_parent().remove_child(node)
		node.queue_free()
	_spawned.clear()


func _exit_tree() -> void:
	var net := MpfRuntime.net()
	if net != null and net.world == self:
		net.world = null


func register_scene(key: StringName, scene: PackedScene) -> void:
	scenes[key] = scene


## Server only. Spawns [param key] on every peer and returns the local node.
## [param props] are applied to matching exported properties of the root.
func spawn(key: StringName, props: Dictionary = {}, owner_peer_id: int = 1) -> Node:
	if not MpfRuntime.is_server():
		MpfLog.warn("net", "Only the server may spawn", {"key": String(key)})
		return null
	if not scenes.has(key):
		MpfLog.error("net", "Unknown spawn key", {"key": String(key)})
		return null
	var net := MpfRuntime.net()
	_sequence += 1
	return _spawner.spawn({
		"k": String(key),
		"n": "%s#%d" % [key, _sequence],
		"i": net.allocate_net_id() if net != null else _sequence,
		"o": owner_peer_id,
		"p": props,
	})


## Server only. Removing the node on the server removes it everywhere.
func despawn(node: Node) -> void:
	if MpfRuntime.is_server() and is_instance_valid(node):
		_spawned.erase(node)
		node.queue_free()


## Every entity this world spawned that is still alive.
func entities() -> Array[Node]:
	var out: Array[Node] = []
	for node: Node in _spawned:
		if is_instance_valid(node):
			out.append(node)
	return out


func _spawn_from_data(data: Variant) -> Node:
	if typeof(data) != TYPE_DICTIONARY:
		return null
	var info: Dictionary = data
	var key := StringName(info.get("k", ""))
	var scene: PackedScene = scenes.get(key)
	if scene == null:
		MpfLog.error("net", "Cannot spawn unknown key", {"key": String(key)})
		return null
	var node := scene.instantiate()
	node.name = String(info.get("n", String(key)))
	var identity := MpfNetIdentity.of(node)
	if identity != null:
		identity.net_id = int(info.get("i", 0))
		identity.owner_peer_id = int(info.get("o", 1))
	var props: Dictionary = info.get("p", {}) as Dictionary
	_apply_props(node, props)
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
