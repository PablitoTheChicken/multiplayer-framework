@tool
class_name MpfNetRigidBody
extends Node
## Makes a RigidBody parent safe to replicate.
##
## Godot physics is not deterministic across machines, so letting every peer
## simulate the same body guarantees they disagree. Exactly one peer simulates;
## everyone else stops simulating and follows the replicated transform.
##
## Add it beside an [MpfNetIdentity] and an [MpfNetTransform] on a [RigidBody3D]
## or [RigidBody2D]. The body itself is left completely alone on the authority -
## mass, damping, physics material and layers all behave normally.

## Stop sending while the body sleeps, and resume when it wakes. A warehouse of
## settled crates then costs no bandwidth at all.
@export var sleep_gating: bool = true
## What non-authoritative copies become. Kinematic still pushes other bodies
## and carries riders; static is cheaper but inert.
@export_enum("Kinematic", "Static") var remote_freeze_mode: int = 0

var _body: Node = null
var _identity: MpfNetIdentity = null
var _transform: MpfNetTransform = null
var _is_3d: bool = true
var _authored_freeze: bool = false
var _was_sleeping: bool = false


func _get_configuration_warnings() -> PackedStringArray:
	var problems := PackedStringArray()
	var parent := get_parent()
	if not (parent is RigidBody3D or parent is RigidBody2D):
		problems.append("Parent must be a RigidBody3D or RigidBody2D.")
	elif MpfUtil.find_child_of_type(parent, MpfNetTransform) == null:
		problems.append("Needs an MpfNetTransform on the same entity to carry the motion.")
	if MpfNetIdentity.of(self) == null:
		problems.append("Needs an MpfNetIdentity on the same entity.")
	return problems


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	_body = get_parent()
	if not (_body is RigidBody3D or _body is RigidBody2D):
		MpfLog.error("net", "MpfNetRigidBody needs a RigidBody parent", {"path": String(get_path())})
		return
	_is_3d = _body is RigidBody3D
	_identity = MpfNetIdentity.of(self)
	_transform = MpfUtil.find_child_of_type(_body, MpfNetTransform) as MpfNetTransform
	if _identity == null:
		MpfLog.error("net", "MpfNetRigidBody needs an MpfNetIdentity on the entity", {"path": String(get_path())})
		return
	_authored_freeze = bool(_body.get("freeze"))
	_identity.owner_changed.connect(func(_peer_id: int) -> void: apply_authority())
	var net := MpfRuntime.net()
	if net != null:
		net.register_replicator(self)
	apply_authority()


func _exit_tree() -> void:
	if Engine.is_editor_hint():
		return
	var net := MpfRuntime.net()
	if net != null:
		net.unregister_replicator(self)


## Puts the body into the right mode for this peer. Called automatically, and
## again whenever authority changes.
func apply_authority() -> void:
	if _body == null or _identity == null:
		return
	var mine := _identity.is_authority()
	if mine:
		_body.set("freeze", _authored_freeze)
		return
	# Freezing is what stops the solver fighting the incoming transform. Both
	# RigidBody3D and RigidBody2D use 0 for static and 1 for kinematic.
	const FREEZE_STATIC := 0
	const FREEZE_KINEMATIC := 1
	_body.set("freeze_mode", FREEZE_KINEMATIC if remote_freeze_mode == 0 else FREEZE_STATIC)
	_body.set("freeze", true)
	_body.set("sleeping", false)


func is_simulating() -> bool:
	return _identity != null and _identity.is_authority()


func is_sleeping() -> bool:
	return _body != null and bool(_body.get("sleeping"))


## Server-side push. Wakes the body so replication resumes, then applies the
## impulse; the resulting motion replicates by itself through the transform.
func push(impulse: Variant, at_offset: Variant = null) -> void:
	if not is_simulating() or _body == null:
		return
	wake()
	if at_offset == null:
		_body.call("apply_impulse", impulse)
	else:
		_body.call("apply_impulse", impulse, at_offset)


## Server-side torque impulse.
func spin(impulse: Variant) -> void:
	if not is_simulating() or _body == null:
		return
	wake()
	_body.call("apply_torque_impulse", impulse)


## Moves the body and pushes the new position out immediately, rather than
## waiting for the next tick. Use for respawns and teleporters.
func teleport(to: Variant) -> void:
	if not is_simulating() or _body == null:
		return
	if _is_3d:
		(_body as Node3D).global_position = to
	else:
		(_body as Node2D).global_position = to
	wake()
	if _transform != null:
		_transform.paused = false
		_transform.force_sync()


func wake() -> void:
	if _body != null:
		_body.set("sleeping", false)


## Watches for the body settling or waking, and gates the transform accordingly.
func _mpf_replicate(_index: int) -> void:
	if not sleep_gating or _transform == null or not is_simulating():
		return
	var sleeping := is_sleeping()
	if sleeping == _was_sleeping:
		return
	_was_sleeping = sleeping
	if sleeping:
		# Send the resting pose once before going quiet, so nobody is left
		# interpolating toward a position that is now slightly stale.
		_transform.force_sync()
		_transform.paused = true
	else:
		_transform.paused = false
