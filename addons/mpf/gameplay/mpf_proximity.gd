class_name MpfProximity
extends Node3D
## A point of interest nearby nodes can find by distance and facing.
##
## Pair it with an [MpfProximitySensor] to build proximity prompts, area
## triggers, aggro ranges or "press E to open" hints. It carries no UI and no
## input of its own, so the look and feel stay yours.

signal entered(finder: Node)
signal exited(finder: Node)
signal focused(finder: Node)
signal unfocused(finder: Node)

@export var enabled: bool = true
## Sensors only see points in the group they are looking for.
@export var group: StringName = &"default"
@export var radius: float = 4.0
## How directly the finder must be looking at this, as a dot product against
## its forward vector. 0 disables the check, 0.5 is a wide cone, 0.9 is narrow.
@export var facing_threshold: float = 0.0
@export var require_line_of_sight: bool = false
@export var line_of_sight_mask: int = 1
## Breaks ties when two points are otherwise equally good.
@export var priority: float = 0.0
## Free-form information for whatever UI you build on top.
@export var data: Dictionary = {}

static var _groups: Dictionary = {}


func _ready() -> void:
	var list: Array = _groups.get(group, [])
	list.append(self)
	_groups[group] = list


func _exit_tree() -> void:
	var list: Array = _groups.get(group, [])
	list.erase(self)
	if list.is_empty():
		_groups.erase(group)


## Every registered point in [param in_group], or in all groups when empty.
static func all(in_group: StringName = &"") -> Array[MpfProximity]:
	var out: Array[MpfProximity] = []
	var groups: Array = [in_group] if in_group != &"" else _groups.keys()
	for key: Variant in groups:
		for point: Variant in _groups.get(key, []) as Array:
			if is_instance_valid(point):
				out.append(point)
	return out


## Points within [param max_distance] of [param origin], nearest first.
static func near(origin: Vector3, max_distance: float, in_group: StringName = &"") -> Array[MpfProximity]:
	var found: Array[MpfProximity] = []
	for point: MpfProximity in all(in_group):
		if point.enabled and point.global_position.distance_to(origin) <= minf(max_distance, point.radius):
			found.append(point)
	found.sort_custom(func(a: MpfProximity, b: MpfProximity) -> bool:
		return a.global_position.distance_squared_to(origin) < b.global_position.distance_squared_to(origin))
	return found


## The single best candidate for a finder at [param origin] looking along
## [param forward], or null. [param filter] is an optional
## `func(point: MpfProximity) -> bool`.
static func best(origin: Vector3, forward: Vector3, max_distance: float, in_group: StringName = &"", filter: Callable = Callable()) -> MpfProximity:
	var winner: MpfProximity = null
	var winning_score := -INF
	for point: MpfProximity in all(in_group):
		if filter.is_valid() and not bool(filter.call(point)):
			continue
		var score := point.score_for(origin, forward, max_distance)
		if score > winning_score:
			winning_score = score
			winner = point
	return winner


## Score for a finder at [param origin]; -INF means "not a candidate".
func score_for(origin: Vector3, forward: Vector3, max_distance: float) -> float:
	if not enabled:
		return -INF
	var limit := minf(max_distance, radius) if max_distance > 0.0 else radius
	var offset := global_position - origin
	var distance := offset.length()
	if distance > limit:
		return -INF
	var alignment := 1.0
	if facing_threshold > 0.0 and distance > 0.001:
		alignment = forward.normalized().dot(offset / distance)
		if alignment < facing_threshold:
			return -INF
	if require_line_of_sight and not has_line_of_sight(origin):
		return -INF
	# Closer and more directly faced both raise the score; priority breaks ties.
	return priority + (1.0 - distance / maxf(limit, 0.001)) + alignment


func has_line_of_sight(from: Vector3) -> bool:
	var space := get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(from, global_position)
	query.collision_mask = line_of_sight_mask
	var parent := get_parent()
	if parent is CollisionObject3D:
		query.exclude = [(parent as CollisionObject3D).get_rid()]
	return space.intersect_ray(query).is_empty()


func get_data(key: StringName, default_value: Variant = null) -> Variant:
	if data.has(key):
		return data[key]
	return data.get(String(key), default_value)
