@tool
class_name MpfNetIdentity
extends Node
## Gives the parent node a network id and an owner. Add it as a child of any
## node that other components need to address across the wire.

signal owner_changed(peer_id: int)

enum Authority {
	SERVER, ## Only the server may change this entity.
	OWNER, ## The owning client may change it, and the server relays.
}

@export var authority: Authority = Authority.SERVER
## Left at 0, the id is derived from the scene path, which every peer agrees on
## for scene-placed nodes. Spawned entities get one allocated by the server.
@export var net_id: int = 0
@export var owner_peer_id: int = 1
## Beyond this distance from a peer, that peer is not sent state or transform
## updates for this entity. 0 keeps it always relevant.
##
## This is interest management, and it is what lets a survival world hold
## hundreds of entities without every peer paying for all of them. Set it on
## anything numerous and local: crates, doors, animals, dropped loot. Leave it
## at 0 for things that must stay correct at any distance, like objectives.
@export var relevancy_range: float = 0.0

var _registered: int = 0
var _registered_node: Node = null
var _actions: Dictionary = {}


func _get_configuration_warnings() -> PackedStringArray:
	var problems := PackedStringArray()
	if get_parent() == null:
		problems.append("Add this as a child of the entity it identifies, not as the scene root.")
	for sibling: Node in (get_parent().get_children() if get_parent() != null else []):
		if sibling != self and sibling is MpfNetIdentity:
			problems.append("Two MpfNetIdentity nodes on one entity - components will bind to whichever is found first.")
			break
	return problems


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	if net_id == 0:
		net_id = MpfUtil.stable_hash(String(get_path()))
	var net := MpfRuntime.net()
	if net != null:
		net.register_entity(net_id, entity())
		net.register_receiver(net_id, &"__act", _receive_action)
		if relevancy_range > 0.0:
			net.register_relevancy(net_id, entity(), relevancy_range)
		if authority == Authority.OWNER:
			net.register_player_node(owner_peer_id, entity())
		_registered = net_id
		# Remembered rather than re-derived, because get_parent() is not
		# dependable by the time _exit_tree runs during a cascading free.
		_registered_node = entity()


func _exit_tree() -> void:
	if Engine.is_editor_hint():
		return
	var net := MpfRuntime.net()
	if net != null and _registered != 0:
		net.unregister_entity(_registered, _registered_node)
	_registered = 0
	_registered_node = null


## Used by [MpfAction] so several actions can share one entity mailbox.
## [param receiver] takes (sender_id, message).
func register_action(action_name: StringName, receiver: Callable) -> void:
	_actions[action_name] = receiver


func unregister_action(action_name: StringName) -> void:
	_actions.erase(action_name)


func _receive_action(sender: int, data: Variant) -> bool:
	if typeof(data) != TYPE_DICTIONARY:
		return false
	var message: Dictionary = data
	var receiver: Callable = _actions.get(StringName(message.get("a", "")), Callable())
	if receiver.is_valid():
		receiver.call(sender, message)
	return false


## The gameplay node this identity belongs to.
func entity() -> Node:
	var parent := get_parent()
	return parent if parent != null else self


func is_authority() -> bool:
	if authority == Authority.OWNER:
		return MpfRuntime.local_id() == owner_peer_id
	return MpfRuntime.is_server()


func is_owner() -> bool:
	return MpfRuntime.local_id() == owner_peer_id


## Server only. Hands the entity to another peer.
func set_owner_peer(peer_id: int) -> void:
	if owner_peer_id == peer_id:
		return
	owner_peer_id = peer_id
	var net := MpfRuntime.net()
	if net != null and authority == Authority.OWNER:
		net.register_player_node(peer_id, entity())
	owner_changed.emit(peer_id)


## Finds the identity for [param node]: on its children, then up its ancestors.
static func of(node: Node) -> MpfNetIdentity:
	if node == null:
		return null
	if node is MpfNetIdentity:
		return node
	var found := MpfUtil.find_child_of_type(node, MpfNetIdentity)
	if found != null:
		return found
	# Walk up, but never past the spawn root: an unrelated ancestor's identity
	# would silently bind this component to the wrong entity.
	var cursor := node.get_parent()
	while cursor != null and not (cursor is MpfNetWorld):
		for child: Node in cursor.get_children():
			if child is MpfNetIdentity:
				return child
		cursor = cursor.get_parent()
	return null
