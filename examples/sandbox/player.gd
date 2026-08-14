extends CharacterBody3D
## Demo avatar. Only the owning peer simulates it; [MpfNetTransform] replicates
## the result to everyone else, so movement code stays single-player shaped.

@export var spawn_position: Vector3 = Vector3.ZERO
@export var speed: float = 6.0
@export var jump_velocity: float = 5.0
@export var mouse_sensitivity: float = 0.0025
@export var min_pitch_degrees: float = -70.0
@export var max_pitch_degrees: float = 40.0

@onready var identity: MpfNetIdentity = $NetIdentity
@onready var state: MpfNetState = $NetState
@onready var sensor: MpfProximitySensor = $ProximitySensor
@onready var pivot: Node3D = $CameraPivot
@onready var camera: Camera3D = $CameraPivot/SpringArm3D/Camera3D

var _focus: MpfProximity = null
var _focus_action: StringName = &""
var _held: Node = null


func _ready() -> void:
	global_position = spawn_position
	state.define(&"health", 100.0)
	sensor.focus_changed.connect(_on_focus_changed)
	MPF.events.on(&"crate_held", _on_crate_held)
	# Ownership is not fixed for the lifetime of the entity: the server can
	# hand it to another peer, and a reconnect gives this machine a new peer id.
	# Caching "is this mine" once in _ready leaves stale copies still eating
	# input, so re-apply it whenever the owner changes.
	identity.owner_changed.connect(func(_peer_id: int) -> void: _apply_ownership())
	_apply_ownership()


## Input, camera and the prompt scan are local-player-only. Remote copies are
## moved purely by the replicated transform.
func _apply_ownership() -> void:
	var mine := identity.is_owner()
	camera.current = mine
	sensor.enabled = mine
	set_physics_process(mine)
	set_process_unhandled_input(mine)
	if mine:
		_capture_mouse(true)
	else:
		_focus = null


func _physics_process(delta: float) -> void:
	if not is_on_floor():
		velocity += get_gravity() * delta
	elif Input.is_action_just_pressed("jump"):
		velocity.y = jump_velocity
	var input := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	# Body yaw follows the mouse, so its basis already points where you look.
	var direction := (transform.basis * Vector3(input.x, 0.0, input.y)).normalized()
	velocity.x = direction.x * speed
	velocity.z = direction.z * speed
	move_and_slide()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_mouse"):
		_capture_mouse(Input.mouse_mode != Input.MOUSE_MODE_CAPTURED)
		return
	if event.is_action_pressed("interact"):
		if _held != null:
			_throw_held()
		elif _focus != null:
			sensor.trigger_focus(_focus_action, {"dir": aim_direction()})
		return
	var motion := event as InputEventMouseMotion
	if motion == null or Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		return
	# Yaw turns the whole body so movement and aim stay aligned; pitch only
	# tilts the camera, and is never replicated because nobody else needs it.
	rotate_y(-motion.relative.x * mouse_sensitivity)
	pivot.rotation.x = clampf(
		pivot.rotation.x - motion.relative.y * mouse_sensitivity,
		deg_to_rad(min_pitch_degrees),
		deg_to_rad(max_pitch_degrees)
	)


func aim_direction() -> Vector3:
	return -camera.global_transform.basis.z


## The framework reports what is in focus; the prompt UI stays the game's job.
## Which action a prompt fires comes from its own data, so the player does not
## need to know what kinds of things exist in the world.
func _on_focus_changed(current: MpfProximity, _previous: MpfProximity) -> void:
	_focus = current
	_focus_action = StringName(current.get_data(&"action", "interact")) if current != null else &""
	_refresh_prompt()


func _throw_held() -> void:
	for candidate: Node in MpfUtil.find_children_of_type(_held, MpfAction):
		var action := candidate as MpfAction
		if action.action_name == &"grab":
			action.request({"dir": aim_direction()})
			return


func _on_crate_held(payload: Dictionary) -> void:
	var crate: Node = payload.get("crate")
	if int(payload.get("peer", 0)) == identity.owner_peer_id:
		_held = crate
	elif _held == crate:
		_held = null
	_refresh_prompt()


func _refresh_prompt() -> void:
	var text := ""
	if _held != null:
		text = "[E] Throw"
	elif _focus != null:
		text = "[E] %s" % String(_focus.get_data(&"prompt", "Interact"))
	MPF.events.emit(&"prompt", {"text": text})


func _capture_mouse(captured: bool) -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if captured else Input.MOUSE_MODE_VISIBLE
