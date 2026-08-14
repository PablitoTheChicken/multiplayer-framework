extends RigidBody3D
## A crate you can pick up and throw, showing physics replication end to end.
##
## The server owns the simulation. Carrying is done by steering the body's
## velocity toward the holder's hands rather than teleporting it, so a carried
## crate still collides with the world, and throwing is a single impulse the
## server applies - the motion replicates by itself.

@export var carry_distance: float = 2.0
@export var carry_height: float = 0.6
@export var carry_stiffness: float = 14.0
@export var carry_speed_limit: float = 14.0
@export var throw_force: float = 9.0

@onready var state: MpfNetState = $NetState
@onready var rigid: MpfNetRigidBody = $NetRigidBody
@onready var grab: MpfAction = $GrabAction
@onready var point: MpfProximity = $Prompt


func _ready() -> void:
	state.define(&"held_by", 0)
	state.changed.connect(_on_state_changed)
	grab.performed.connect(_on_grab)
	# Only the server steers a carried crate; everyone else sees the result.
	set_physics_process(Net.is_server())


func _physics_process(delta: float) -> void:
	var holder := int(state.get_value(&"held_by", 0))
	if holder == 0:
		return
	var carrier := Net.player_node(holder) as Node3D
	if carrier == null:
		# The holder disconnected mid-carry; drop it rather than leave it stuck.
		state.set_value(&"held_by", 0)
		return
	var target := carrier.global_position \
		+ (-carrier.global_transform.basis.z * carry_distance) \
		+ Vector3.UP * carry_height
	var wanted := (target - global_position) * carry_stiffness
	linear_velocity = wanted.limit_length(carry_speed_limit)
	angular_velocity = angular_velocity * (1.0 - clampf(delta * 6.0, 0.0, 1.0))


## Pressing interact grabs a free crate, or throws the one you are holding.
func _on_grab(peer_id: int, payload: Dictionary) -> void:
	if not Net.is_server():
		return
	var holder := int(state.get_value(&"held_by", 0))
	if holder == 0:
		state.set_value(&"held_by", peer_id)
		rigid.wake()
	elif holder == peer_id:
		state.set_value(&"held_by", 0)
		var direction: Vector3 = payload.get("dir", Vector3.FORWARD)
		if direction.length() > 0.01:
			rigid.push(direction.normalized() * throw_force)


func _on_state_changed(key: StringName, value: Variant, _previous: Variant) -> void:
	if key != &"held_by":
		return
	var holder := int(value)
	# Carried crates should not offer themselves to other players, and the
	# holder needs to know what they are carrying so they can throw it.
	point.enabled = holder == 0
	point.data["prompt"] = "Pick up"
	MPF.events.emit(&"crate_held", {"crate": self, "peer": holder})
