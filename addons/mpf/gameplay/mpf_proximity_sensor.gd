@tool
class_name MpfProximitySensor
extends Node
## Tracks which [MpfProximity] point its parent is best positioned to use.
##
## Connect [signal focus_changed] to show and hide a prompt, and call
## [method trigger_focus] on input to fire the focused point's action. Attach
## it to a player or camera rig.

signal focus_changed(current: MpfProximity, previous: MpfProximity)
signal entered_range(point: MpfProximity)
signal left_range(point: MpfProximity)

@export var enabled: bool = true
@export var group: StringName = &"default"
@export var max_distance: float = 6.0
## Seconds between scans. Prompts do not need to run every frame.
@export var poll_interval: float = 0.08
## Node whose -Z axis is the look direction. Empty uses the active camera.
@export var forward_source: NodePath

## Optional `func(point: MpfProximity) -> bool` for game-specific rules.
var filter: Callable = Callable()
var focus: MpfProximity = null

var _origin_node: Node3D = null
var _in_range: Array[MpfProximity] = []
var _timer: float = 0.0


func _get_configuration_warnings() -> PackedStringArray:
	if not (get_parent() is Node3D):
		return ["Parent must be a Node3D - the sensor scans outward from its position."]
	return []


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	_origin_node = get_parent() as Node3D
	if _origin_node == null:
		MpfLog.error("proximity", "MpfProximitySensor needs a Node3D parent", {"path": String(get_path())})
		set_process(false)


func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	if not enabled:
		if focus != null:
			_set_focus(null)
		return
	_timer += delta
	if _timer < poll_interval:
		return
	_timer = 0.0
	scan()


## Runs a scan immediately rather than waiting for the next poll.
func scan() -> void:
	var origin := _origin_node.global_position
	var forward := _forward()
	_update_range(MpfProximity.near(origin, max_distance, group))
	_set_focus(MpfProximity.best(origin, forward, max_distance, group, filter))


## Points currently within range, nearest first.
func in_range() -> Array[MpfProximity]:
	return _in_range.duplicate()


## Convenience for input handling: fires [param action] on the focused point's
## entity, if it has one. Returns whether anything was triggered.
func trigger_focus(action_name: StringName, payload: Dictionary = {}) -> bool:
	if focus == null:
		return false
	for candidate: Node in MpfUtil.find_children_of_type(focus.get_parent(), MpfAction):
		var action := candidate as MpfAction
		if action.action_name == action_name:
			action.request(payload)
			return true
	return false


func _forward() -> Vector3:
	if not forward_source.is_empty():
		var source := get_node_or_null(forward_source) as Node3D
		if source != null:
			return -source.global_transform.basis.z
	var camera := _origin_node.get_viewport().get_camera_3d()
	if camera != null:
		return -camera.global_transform.basis.z
	return -_origin_node.global_transform.basis.z


func _update_range(found: Array[MpfProximity]) -> void:
	for point: MpfProximity in found:
		if not _in_range.has(point):
			point.entered.emit(_origin_node)
			entered_range.emit(point)
	for point: MpfProximity in _in_range:
		if is_instance_valid(point) and not found.has(point):
			point.exited.emit(_origin_node)
			left_range.emit(point)
	_in_range = found


func _set_focus(next: MpfProximity) -> void:
	if next == focus:
		return
	var previous := focus
	focus = next
	if is_instance_valid(previous):
		previous.unfocused.emit(_origin_node)
	if next != null:
		next.focused.emit(_origin_node)
	focus_changed.emit(next, previous)
