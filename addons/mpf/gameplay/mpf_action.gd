@tool
class_name MpfAction
extends Node
## A request a client makes that the server validates before anyone applies it.
##
## Attacks, interactions, ability casts, purchases and door opens all share one
## shape: the client asks, the server checks what only it can trust, then
## everyone applies the confirmed result. Declaring that shape once means the
## rate limit, cooldown, range and line-of-sight checks are not rewritten, or
## forgotten, per feature. Requires an [MpfNetIdentity] on the entity.

## Fired on every peer once the server confirms the action.
signal performed(peer_id: int, payload: Dictionary)
## Fired only on the requesting peer when the server refuses.
signal rejected(reason: String)
## Fired locally the instant [method request] is called, before the round trip.
signal predicted(payload: Dictionary)

@export var action_name: StringName = &"action"
@export var cooldown: float = 0.0
## Requests per second accepted from one peer. 0 disables the limit.
@export var rate: float = 10.0
## Maximum distance from the requesting peer's avatar. 0 disables the check.
@export var max_range: float = 0.0
@export var require_line_of_sight: bool = false
@export var line_of_sight_mask: int = 1
## Confirm to everyone, or only to the peer that asked.
@export var confirm_to_all: bool = true
## Emit [signal predicted] locally so effects start before the server replies.
@export var predict_locally: bool = false
## Optional [MpfSchema] description of the payload.
@export var payload_schema: Dictionary = {}

## Optional `func(peer_id: int, payload: Dictionary) -> String`. Return an
## empty string to allow, or a reason to refuse. Runs after the built-in checks.
var validator: Callable = Callable()
## Optional `func(peer_id: int) -> Node` overriding how the requester's avatar
## is found. Defaults to the node registered by an owner-authority identity.
var actor_provider: Callable = Callable()

var _identity: MpfNetIdentity = null
var _net: Node = null
var _limiter := MpfRate.new()
var _cooldowns: Dictionary = {}


func _get_configuration_warnings() -> PackedStringArray:
	var problems := PackedStringArray()
	if MpfNetIdentity.of(self) == null:
		problems.append("Needs an MpfNetIdentity on the same entity. Add one as a sibling.")
	if String(action_name).is_empty() or action_name == &"action":
		problems.append("Give this a distinct action_name; entities route requests by that name.")
	if (max_range > 0.0 or require_line_of_sight) and not (get_parent() is Node3D):
		problems.append("Range and line-of-sight checks need a Node3D parent to measure from.")
	return problems


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	_identity = MpfNetIdentity.of(self)
	_net = MpfRuntime.net()
	if _identity == null:
		MpfLog.error("action", "MpfAction needs an MpfNetIdentity on the entity", {"path": String(get_path())})
		return
	_identity.register_action(action_name, _receive)
	if _net != null:
		_net.peer_left.connect(_on_peer_left)


func _exit_tree() -> void:
	if Engine.is_editor_hint():
		return
	if _identity != null:
		_identity.unregister_action(action_name)
	if _net != null and _net.peer_left.is_connected(_on_peer_left):
		_net.peer_left.disconnect(_on_peer_left)


## Cooldown and rate-limit entries are keyed by peer, so drop them on
## disconnect rather than accumulating one per peer a server ever saw.
func _on_peer_left(peer: MpfPeer, _reason: String) -> void:
	_cooldowns.erase(peer.id)
	_limiter.forget(peer.id)


## Asks the server to perform the action. Safe to call on any peer; on a
## server or in single player it runs the validation path immediately.
func request(payload: Dictionary = {}) -> void:
	if predict_locally:
		predicted.emit(payload)
	if MpfRuntime.is_server():
		_handle_request(MpfRuntime.local_id(), payload)
		return
	if _net == null or _identity == null:
		return
	_net.send_to_server(&"__act", {_identity.net_id: {"a": String(action_name), "p": payload}})


## Server only. Performs the action without validating it, for effects the
## game itself triggers rather than a player.
func force(peer_id: int, payload: Dictionary = {}) -> void:
	if MpfRuntime.is_server():
		_confirm(peer_id, payload)


func remaining_cooldown(peer_id: int = 0) -> float:
	var id := peer_id if peer_id != 0 else MpfRuntime.local_id()
	return maxf(0.0, float(_cooldowns.get(id, 0.0)) - MpfRuntime.server_time())


func is_ready(peer_id: int = 0) -> bool:
	return remaining_cooldown(peer_id) <= 0.0


func _receive(sender: int, message: Dictionary) -> void:
	if bool(message.get("c", false)):
		_on_confirmed(message)
	elif MpfRuntime.is_server():
		_handle_request(sender, message.get("p", {}) as Dictionary)


func _on_confirmed(message: Dictionary) -> void:
	if message.has("r"):
		rejected.emit(String(message["r"]))
		return
	var by := int(message.get("by", 0))
	if cooldown > 0.0:
		_cooldowns[by] = MpfRuntime.server_time() + cooldown
	performed.emit(by, message.get("p", {}) as Dictionary)


func _handle_request(peer_id: int, payload: Dictionary) -> void:
	var reason := _check(peer_id, payload)
	if reason == "":
		_confirm(peer_id, payload)
	else:
		_reject(peer_id, reason)


func _confirm(peer_id: int, payload: Dictionary) -> void:
	if cooldown > 0.0:
		_cooldowns[peer_id] = MpfRuntime.server_time() + cooldown
	performed.emit(peer_id, payload)
	if _net == null or _identity == null:
		return
	var message := {"a": String(action_name), "p": payload, "by": peer_id, "c": true}
	if confirm_to_all:
		_net.send_to_all(&"__actc", {_identity.net_id: message}, [_net.local_id()])
	elif peer_id != _net.local_id():
		_net.send_to(&"__actc", peer_id, {_identity.net_id: message})


func _reject(peer_id: int, reason: String) -> void:
	MpfLog.debug("action", "Rejected", {"action": String(action_name), "peer": peer_id, "reason": reason})
	if _net == null or _identity == null or peer_id == MpfRuntime.local_id():
		rejected.emit(reason)
		return
	_net.send_to(&"__actc", peer_id, {_identity.net_id: {"a": String(action_name), "r": reason, "c": true}})


func _check(peer_id: int, payload: Dictionary) -> String:
	if not payload_schema.is_empty():
		var problem := MpfSchema.validate(payload, payload_schema)
		if problem != "":
			return problem
	if rate > 0.0 and not _limiter.allow(peer_id, rate):
		return "too many requests"
	if cooldown > 0.0 and MpfRuntime.server_time() < float(_cooldowns.get(peer_id, 0.0)):
		return "on cooldown"
	if max_range > 0.0 or require_line_of_sight:
		var actor := _actor(peer_id)
		if actor == null:
			return "no avatar registered for this peer"
		var here := _origin()
		var there := _position_of(actor)
		if max_range > 0.0 and here.distance_to(there) > max_range:
			return "out of range"
		if require_line_of_sight and not _has_line_of_sight(there, here, actor):
			return "no line of sight"
	if validator.is_valid():
		return String(validator.call(peer_id, payload))
	return ""


func _actor(peer_id: int) -> Node:
	if actor_provider.is_valid():
		return actor_provider.call(peer_id) as Node
	return _net.player_node(peer_id) if _net != null else null


func _origin() -> Vector3:
	return _position_of(_identity.entity() if _identity != null else get_parent())


static func _position_of(node: Node) -> Vector3:
	if node is Node3D:
		return (node as Node3D).global_position
	if node is Node2D:
		var flat := (node as Node2D).global_position
		return Vector3(flat.x, flat.y, 0.0)
	return Vector3.ZERO


func _has_line_of_sight(from: Vector3, to: Vector3, actor: Node) -> bool:
	var origin_node := _identity.entity() if _identity != null else get_parent()
	if not (origin_node is Node3D):
		return true
	var space := (origin_node as Node3D).get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collision_mask = line_of_sight_mask
	query.exclude = _collision_exclusions(actor, origin_node)
	return space.intersect_ray(query).is_empty()


static func _collision_exclusions(actor: Node, target: Node) -> Array[RID]:
	var out: Array[RID] = []
	for node: Node in [actor, target]:
		if node is CollisionObject3D:
			out.append((node as CollisionObject3D).get_rid())
	return out
