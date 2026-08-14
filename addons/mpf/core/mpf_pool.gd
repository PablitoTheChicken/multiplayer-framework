class_name MpfPool
extends RefCounted
## Node pool for short-lived scene instances. Pooled nodes may implement
## [code]_pool_acquired()[/code] and [code]_pool_released()[/code].

var _scene: PackedScene
var _parent: Node
var _free: Array[Node] = []
var _live: Array[Node] = []
var _max_idle: int


func _init(scene: PackedScene, parent: Node, prewarm: int = 0, max_idle: int = 64) -> void:
	_scene = scene
	_parent = parent
	_max_idle = maxi(1, max_idle)
	for i: int in prewarm:
		var node := _instantiate()
		if node != null:
			_deactivate(node)
			_free.append(node)


func acquire() -> Node:
	var node: Node = null
	while node == null and not _free.is_empty():
		node = _free.pop_back()
		if not is_instance_valid(node):
			node = null
	if node == null:
		node = _instantiate()
	if node == null:
		return null
	_activate(node)
	_live.append(node)
	if node.has_method("_pool_acquired"):
		node.call("_pool_acquired")
	return node


## Returns a node to the pool. Instances beyond [member _max_idle] are freed so
## a burst does not permanently inflate memory.
func release(node: Node) -> void:
	if not is_instance_valid(node):
		return
	_live.erase(node)
	if node.has_method("_pool_released"):
		node.call("_pool_released")
	if _free.size() >= _max_idle:
		node.queue_free()
		return
	_deactivate(node)
	_free.append(node)


func release_all() -> void:
	for node: Node in _live.duplicate():
		release(node)


func clear() -> void:
	for node: Node in _live + _free:
		if is_instance_valid(node):
			node.queue_free()
	_live.clear()
	_free.clear()


func live_count() -> int:
	return _live.size()


func idle_count() -> int:
	return _free.size()


func _instantiate() -> Node:
	if _scene == null or not is_instance_valid(_parent):
		MpfLog.error("pool", "Pool has no scene or parent")
		return null
	var node := _scene.instantiate()
	_parent.add_child(node)
	return node


func _activate(node: Node) -> void:
	node.set_process(true)
	node.set_physics_process(true)
	if node is CanvasItem:
		(node as CanvasItem).visible = true
	elif node is Node3D:
		(node as Node3D).visible = true


func _deactivate(node: Node) -> void:
	node.set_process(false)
	node.set_physics_process(false)
	if node is CanvasItem:
		(node as CanvasItem).visible = false
	elif node is Node3D:
		(node as Node3D).visible = false
