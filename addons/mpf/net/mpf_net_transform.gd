@tool
class_name MpfNetTransform
extends Node
## Replicates the parent's transform, with snapshot interpolation on the
## receiving side. Works with both [Node3D] and [Node2D] parents.
##
## Non-authoritative peers render slightly in the past
## ([member interpolation_delay_ms]) so there is always a newer snapshot to
## interpolate toward, which trades a little latency for motion with no
## stutter or rubber-banding.

@export var sync_position: bool = true
@export var sync_rotation: bool = true
@export var sync_scale: bool = false
## Send at most every N ticks. 2 at a 30 Hz tick is 15 updates a second.
@export var send_every_n_ticks: int = 2
@export var interpolate: bool = true
@export var interpolation_delay_ms: float = 100.0
@export var position_epsilon: float = 0.005
@export var rotation_epsilon_degrees: float = 0.25
## A jump larger than this is treated as a teleport and snapped to, not slid to.
@export var teleport_distance: float = 20.0
## Extra snapshots sent after an entity stops moving.
##
## Transform updates are unreliable, and an entity that comes to rest stops
## sending. If the last packets are the ones that drop, every other peer is left
## holding a stale position forever. Repeating the resting pose a few times
## makes that vanishingly unlikely without costing anything while idle.
@export var settle_repeats: int = 3
## Server-side sanity limit in metres per second for owner-authoritative
## entities. 0 disables the check.
##
## This is not anti-cheat in the competitive sense - a client that moves at a
## plausible speed is still trusted. It stops the cases that actually ruin a
## co-op session: a modified client teleporting across the map, and a physics
## glitch flinging someone into the void. Set it comfortably above your real
## top speed so dashes and knockback survive.
@export var max_server_speed: float = 0.0
## Replicate relative to this node instead of world space. 3D only.
##
## A player standing on a moving ship has a world position that changes every
## frame even when they are standing still, so world-space replication makes
## them slide and jitter. Replicating in the ship's local space means only real
## movement is sent, and riders stay glued while the ship moves and turns.
##
## The frame is identified over the wire by its net id, so it resolves on every
## peer whether the ship is scene-placed or spawned.
@export var reference_frame: NodePath

var _frame: Node3D = null
var _remote_frame_id: int = 0

var _validated_position := Vector3.ZERO
var _validated_at: float = 0.0
var _has_validated: bool = false

## While true the authority stops sending updates. [MpfNetRigidBody] uses this
## to silence bodies that have gone to sleep. Late-join sync still works, so a
## paused entity is not an invisible one.
var paused: bool = false

var _identity: MpfNetIdentity = null
var _net: Node = null
var _target: Node = null
var _is_3d: bool = true
var _buffer := MpfRing.new(24)
var _last_sent_position := Vector3.ZERO
var _last_sent_rotation := Vector3.ZERO
var _has_sent: bool = false
var _settle_sends: int = 0


func _get_configuration_warnings() -> PackedStringArray:
	var problems := PackedStringArray()
	var parent := get_parent()
	if not (parent is Node3D or parent is Node2D):
		problems.append("Parent must be a Node3D or Node2D - there is no transform to replicate.")
	if MpfNetIdentity.of(self) == null:
		problems.append("Needs an MpfNetIdentity on the same entity. Add one as a sibling.")
	if parent is RigidBody3D or parent is RigidBody2D:
		problems.append("RigidBody parents fight this component: the solver and the replicated transform both write the position. Freeze the body on non-authoritative peers.")
	return problems


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	_target = get_parent()
	_is_3d = _target is Node3D
	if not (_target is Node3D or _target is Node2D):
		MpfLog.error("net", "MpfNetTransform needs a Node3D or Node2D parent", {"path": String(get_path())})
		set_process(false)
		return
	_identity = MpfNetIdentity.of(self)
	_net = MpfRuntime.net()
	if _identity == null:
		MpfLog.error("net", "MpfNetTransform needs an MpfNetIdentity on the entity", {"path": String(get_path())})
		set_process(false)
		return
	if _net != null:
		_net.register_receiver(_identity.net_id, &"__tf", _receive)
		# peer_ready, not peer_joined: the entity is only sent once the peer has
		# finished loading, and a transform that arrives before it is discarded.
		_net.peer_ready.connect(_on_peer_ready)
		_net.register_replicator(self)


func _exit_tree() -> void:
	if Engine.is_editor_hint():
		return
	if _net != null and _identity != null:
		_net.unregister_receiver(_identity.net_id, &"__tf")
		_net.unregister_replicator(self)
		if _net.peer_ready.is_connected(_on_peer_ready):
			_net.peer_ready.disconnect(_on_peer_ready)


func _process(_delta: float) -> void:
	if Engine.is_editor_hint():
		return
	if _identity == null or _identity.is_authority() or _buffer.is_empty():
		return
	if not interpolate:
		_write(_buffer.newest() as Dictionary)
		return
	var render_time := MpfRuntime.server_time() - interpolation_delay_ms * 0.001
	var older: Dictionary = {}
	var newer: Dictionary = {}
	for snapshot: Dictionary in _buffer.to_array():
		if float(snapshot["t"]) <= render_time:
			older = snapshot
		elif newer.is_empty():
			newer = snapshot
	if older.is_empty():
		_write(_buffer.oldest() as Dictionary)
	elif newer.is_empty():
		_write(older)
	else:
		var span := float(newer["t"]) - float(older["t"])
		var weight := 0.0 if span <= 0.0 else clampf((render_time - float(older["t"])) / span, 0.0, 1.0)
		_blend(older, newer, weight)


## Driven by Net's shared replication loop rather than a per-node signal.
func _mpf_replicate(index: int) -> void:
	if paused or _identity == null or _net == null or not _identity.is_authority():
		return
	if send_every_n_ticks > 1 and index % send_every_n_ticks != 0:
		return
	var position := _read_position()
	var rotation := _read_rotation()
	if _has_sent and not _moved(position, rotation):
		if _settle_sends <= 0:
			return
		_settle_sends -= 1
	else:
		_settle_sends = settle_repeats
	_has_sent = true
	_last_sent_position = position
	_last_sent_rotation = rotation
	_net.queue_update(&"__tf", _identity.net_id, _snapshot())


## Sends the current transform to one peer, or to everyone when 0.
func force_sync(peer_id: int = 0) -> void:
	if _identity == null or _net == null or not _identity.is_authority():
		return
	# A client cannot address another client - Godot's topology only lets it
	# talk to the server. For a client-owned entity the update has to go up and
	# be relayed, or a late joiner never learns where it is.
	if not MpfRuntime.is_server():
		_net.send_to_server(&"__tf", {_identity.net_id: _snapshot()})
	elif peer_id == 0:
		_net.send_to_all(&"__tf", {_identity.net_id: _snapshot()}, [_net.local_id()])
	else:
		_net.queue_update_to(peer_id, &"__tf", _identity.net_id, _snapshot())


## Updates are only sent when something moves, so an entity that moved and then
## stopped would appear at its spawn point to anyone who joined afterwards.
func _on_peer_ready(peer: MpfPeer) -> void:
	if peer.id != _net.local_id():
		force_sync(peer.id)


func _snapshot() -> Dictionary:
	var snapshot := {"t": MpfRuntime.server_time()}
	if sync_position:
		snapshot["p"] = _read_position()
	if sync_rotation:
		snapshot["r"] = _read_rotation()
	if sync_scale:
		snapshot["s"] = _read_scale()
	var frame_id := _local_frame_id()
	if frame_id != 0:
		snapshot["f"] = frame_id
	return snapshot


## Attaches this entity to a moving frame at runtime, for a player who steps
## onto a ship. Pass null when they step off.
func set_reference_frame_node(node: Node3D) -> void:
	_frame = node


## The frame this peer replicates against: the authored or assigned node when
## authoritative, otherwise whatever the sender named by net id.
func active_frame() -> Node3D:
	if _identity != null and _identity.is_authority():
		if is_instance_valid(_frame):
			return _frame
		if not reference_frame.is_empty():
			_frame = get_node_or_null(reference_frame) as Node3D
		return _frame
	if _remote_frame_id == 0 or _net == null:
		return null
	return _net.find_entity(_remote_frame_id) as Node3D


func _local_frame_id() -> int:
	if not _is_3d:
		return 0
	var frame := active_frame()
	if frame == null:
		return 0
	var frame_identity := MpfNetIdentity.of(frame)
	return frame_identity.net_id if frame_identity != null else 0


func _moved(position: Vector3, rotation: Vector3) -> bool:
	if sync_position and position.distance_to(_last_sent_position) > position_epsilon:
		return true
	if sync_rotation and rad_to_deg((rotation - _last_sent_rotation).length()) > rotation_epsilon_degrees:
		return true
	return false


func _receive(sender: int, data: Variant) -> bool:
	if typeof(data) != TYPE_DICTIONARY or not _sender_allowed(sender):
		return false
	var snapshot: Dictionary = data
	if not snapshot.has("t"):
		return false
	if not _passes_speed_check(snapshot):
		return false
	_remote_frame_id = int(snapshot.get("f", 0))
	var previous: Variant = _buffer.newest()
	if previous != null and snapshot.has("p"):
		var jump := (snapshot["p"] as Vector3).distance_to((previous as Dictionary).get("p", Vector3.ZERO))
		if jump > teleport_distance:
			_buffer.clear()
	_buffer.push(snapshot)
	return true


## Rejected updates are neither applied nor relayed, and the owner is sent the
## last position the server accepted, which pulls a desynced client back.
func _passes_speed_check(snapshot: Dictionary) -> bool:
	if max_server_speed <= 0.0 or not MpfRuntime.is_server() or not snapshot.has("p"):
		return true
	var position: Vector3 = snapshot["p"]
	var stamp := float(snapshot["t"])
	if not _has_validated:
		_has_validated = true
		_validated_position = position
		_validated_at = stamp
		return true
	var elapsed := maxf(stamp - _validated_at, 0.001)
	# One tick of slack plus a metre, so ordinary jitter is not punished.
	var allowance := max_server_speed * (elapsed + 0.1) + 1.0
	if _validated_position.distance_to(position) > allowance:
		MpfLog.warn("net", "Rejected implausible movement", {
			"entity": _identity.net_id,
			"owner": _identity.owner_peer_id,
			"distance": _validated_position.distance_to(position),
			"allowed": allowance,
		})
		force_sync(_identity.owner_peer_id)
		return false
	_validated_position = position
	_validated_at = stamp
	return true


func _sender_allowed(sender: int) -> bool:
	if _identity == null:
		return false
	if MpfRuntime.is_server():
		return _identity.authority == MpfNetIdentity.Authority.OWNER and sender == _identity.owner_peer_id
	return sender == 1


func _read_position() -> Vector3:
	if _is_3d:
		var world := (_target as Node3D).global_position
		var frame := active_frame()
		return frame.global_transform.affine_inverse() * world if frame != null else world
	var flat := (_target as Node2D).global_position
	return Vector3(flat.x, flat.y, 0.0)


func _read_rotation() -> Vector3:
	if _is_3d:
		var world := (_target as Node3D).global_basis
		var frame := active_frame()
		if frame != null:
			world = frame.global_transform.basis.orthonormalized().inverse() * world
		return world.get_euler()
	return Vector3(0.0, 0.0, (_target as Node2D).global_rotation)


func _read_scale() -> Vector3:
	if _is_3d:
		return (_target as Node3D).scale
	var flat := (_target as Node2D).scale
	return Vector3(flat.x, flat.y, 1.0)


func _write(snapshot: Dictionary) -> void:
	if snapshot.is_empty():
		return
	if sync_position and snapshot.has("p"):
		_write_position(snapshot["p"])
	if sync_rotation and snapshot.has("r"):
		_write_rotation(snapshot["r"])
	if sync_scale and snapshot.has("s"):
		_write_scale(snapshot["s"])


func _blend(older: Dictionary, newer: Dictionary, weight: float) -> void:
	if sync_position and older.has("p") and newer.has("p"):
		_write_position((older["p"] as Vector3).lerp(newer["p"] as Vector3, weight))
	if sync_rotation and older.has("r") and newer.has("r"):
		_write_rotation(_lerp_angles(older["r"], newer["r"], weight))
	if sync_scale and older.has("s") and newer.has("s"):
		_write_scale((older["s"] as Vector3).lerp(newer["s"] as Vector3, weight))


## Snapshots are buffered and interpolated in the frame's space, then converted
## with the frame's *current* transform. That is what keeps a rider glued to a
## ship that has moved since the packet was sent.
func _write_position(value: Vector3) -> void:
	if _is_3d:
		var frame := active_frame()
		(_target as Node3D).global_position = frame.global_transform * value if frame != null else value
	else:
		(_target as Node2D).global_position = Vector2(value.x, value.y)


func _write_rotation(value: Vector3) -> void:
	if _is_3d:
		var frame := active_frame()
		if frame == null:
			(_target as Node3D).global_rotation = value
		else:
			(_target as Node3D).global_basis = frame.global_transform.basis.orthonormalized() * Basis.from_euler(value)
	else:
		(_target as Node2D).global_rotation = value.z


func _write_scale(value: Vector3) -> void:
	if _is_3d:
		(_target as Node3D).scale = value
	else:
		(_target as Node2D).scale = Vector2(value.x, value.y)


## Angles wrap, so interpolate the shortest way round each axis.
static func _lerp_angles(from: Vector3, to: Vector3, weight: float) -> Vector3:
	return Vector3(
		lerp_angle(from.x, to.x, weight),
		lerp_angle(from.y, to.y, weight),
		lerp_angle(from.z, to.z, weight)
	)
