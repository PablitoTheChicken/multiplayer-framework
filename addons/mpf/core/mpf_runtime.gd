class_name MpfRuntime
extends RefCounted
## Locates the MPF autoloads through the scene tree.
##
## Framework code must not reference the [code]Net[/code] / [code]Save[/code]
## globals directly: GDScript resolves autoload names at parse time, so a
## direct reference breaks every addon script until the plugin has been
## enabled once. Game code has no such problem and should use the globals.

const ROOT := "MPF"
const NET := "Net"
const SAVE := "Save"

static var _cache: Dictionary = {}
static var _warned: Dictionary = {}


static func node(singleton: String) -> Node:
	var cached: Node = _cache.get(singleton)
	if is_instance_valid(cached) and cached.is_inside_tree():
		return cached
	var loop := Engine.get_main_loop()
	if loop is SceneTree:
		var found := (loop as SceneTree).root.get_node_or_null(NodePath(singleton))
		_cache[singleton] = found
		if found == null and not _warned.has(singleton):
			_warned[singleton] = true
			MpfLog.warn("runtime", "Autoload missing - is the MPF plugin enabled?", {"name": singleton})
		return found
	return null


static func root() -> Node:
	return node(ROOT)


static func net() -> Node:
	return node(NET)


static func save() -> Node:
	return node(SAVE)


## With no session running the local machine is the authority, which is what
## lets the same gameplay scripts run unchanged in single player.
static func is_server() -> bool:
	var n := net()
	return n == null or bool(n.is_server())


static func is_client() -> bool:
	var n := net()
	return n != null and bool(n.is_client())


static func local_id() -> int:
	var n := net()
	return 1 if n == null else int(n.local_id())


static func server_time() -> float:
	var n := net()
	if n == null:
		return float(Time.get_ticks_msec()) * 0.001
	return float(n.server_time())


static func to_server(channel: StringName, payload: Variant) -> void:
	var n := net()
	if n != null:
		n.send_to_server(channel, payload)


static func to_all(channel: StringName, payload: Variant, exclude: Array = []) -> void:
	var n := net()
	if n != null:
		n.send_to_all(channel, payload, exclude)


static func to_peer(channel: StringName, peer_id: int, payload: Variant) -> void:
	var n := net()
	if n != null:
		n.send_to(channel, peer_id, payload)


static func channel(channel_name: StringName, handler: Callable, options: Dictionary = {}) -> void:
	var n := net()
	if n != null:
		n.register_channel(channel_name, handler, options)


static func invalidate() -> void:
	_cache.clear()
	_warned.clear()
