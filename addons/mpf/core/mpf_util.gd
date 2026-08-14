class_name MpfUtil
extends RefCounted
## Stateless helpers shared across the framework.

static func deep_merge(base: Dictionary, patch: Dictionary) -> Dictionary:
	var out := base.duplicate(true)
	for key: Variant in patch:
		var incoming: Variant = patch[key]
		if typeof(incoming) == TYPE_DICTIONARY and typeof(out.get(key)) == TYPE_DICTIONARY:
			out[key] = deep_merge(out[key], incoming)
		else:
			out[key] = incoming
	return out


## Reads a slash-separated path out of nested dictionaries.
static func dig(source: Dictionary, path: String, default: Variant = null) -> Variant:
	var cursor: Variant = source
	for part: String in path.split("/", false):
		if typeof(cursor) != TYPE_DICTIONARY:
			return default
		var dict: Dictionary = cursor
		if not dict.has(part):
			return default
		cursor = dict[part]
	return cursor


## Writes a slash-separated path, creating intermediate levels. True if changed.
static func bury(target: Dictionary, path: String, value: Variant) -> bool:
	var parts := path.split("/", false)
	if parts.is_empty():
		return false
	var cursor: Dictionary = target
	for i: int in parts.size() - 1:
		var part := parts[i]
		if typeof(cursor.get(part)) != TYPE_DICTIONARY:
			cursor[part] = {}
		cursor = cursor[part]
	var leaf := parts[parts.size() - 1]
	if cursor.has(leaf) and cursor[leaf] == value:
		return false
	cursor[leaf] = value
	return true


## Deterministic across platforms and builds, which is what lets every peer
## derive the same network id for a scene-placed node without the server
## handing ids out.
static func stable_hash(text: String) -> int:
	return int(text.hash()) & 0x7fffffff


static func damp(current: float, target: float, speed: float, delta: float) -> float:
	if speed <= 0.0:
		return target
	return lerpf(target, current, exp(-speed * delta))


static func damp_vector3(current: Vector3, target: Vector3, speed: float, delta: float) -> Vector3:
	if speed <= 0.0:
		return target
	return target.lerp(current, exp(-speed * delta))


static func short_id(length: int = 6) -> String:
	const ALPHABET := "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
	var out := ""
	for i: int in length:
		out += ALPHABET[randi() % ALPHABET.length()]
	return out


static func format_bytes(count: int) -> String:
	const UNITS := ["B", "KiB", "MiB", "GiB"]
	var value := float(count)
	var unit := 0
	while value >= 1024.0 and unit < UNITS.size() - 1:
		value /= 1024.0
		unit += 1
	return "%.1f %s" % [value, UNITS[unit]] if unit > 0 else "%d B" % count


static func find_child_of_type(root: Node, type: Variant, recursive: bool = true) -> Node:
	for child: Node in root.get_children():
		if is_instance_of(child, type):
			return child
		if recursive:
			var found := find_child_of_type(child, type, true)
			if found != null:
				return found
	return null


static func find_children_of_type(root: Node, type: Variant, recursive: bool = true) -> Array[Node]:
	var out: Array[Node] = []
	for child: Node in root.get_children():
		if is_instance_of(child, type):
			out.append(child)
		if recursive:
			out.append_array(find_children_of_type(child, type, true))
	return out


## Compresses a normalised direction to two 16-bit angles.
static func pack_direction(direction: Vector3) -> Vector2i:
	var n := direction.normalized()
	return Vector2i(
		int(roundf(atan2(n.x, n.z) / PI * 32767.0)),
		int(roundf(asin(clampf(n.y, -1.0, 1.0)) / (PI * 0.5) * 32767.0))
	)


static func unpack_direction(packed: Vector2i) -> Vector3:
	var yaw := float(packed.x) / 32767.0 * PI
	var pitch := float(packed.y) / 32767.0 * (PI * 0.5)
	var cos_pitch := cos(pitch)
	return Vector3(sin(yaw) * cos_pitch, sin(pitch), cos(yaw) * cos_pitch)


## Parses "host:port" / "host" / {"host":.., "port":..} into a [host, port] pair.
static func parse_address(target: Variant, default_port: int = 27015) -> Array:
	if typeof(target) == TYPE_DICTIONARY:
		var dict: Dictionary = target
		return [String(dict.get("host", "127.0.0.1")), int(dict.get("port", default_port))]
	var text := String(target).strip_edges()
	var colon := text.rfind(":")
	if colon > 0 and text.substr(colon + 1).is_valid_int():
		return [text.substr(0, colon), int(text.substr(colon + 1))]
	return [text if text != "" else "127.0.0.1", default_port]


## Reads command line arguments in all three common shapes: `--key=value`,
## `--key value`, and bare `--flag` (which yields `true`).
##
## Values are always returned as String or bool, so read them with [method @GlobalScope.str]
## rather than [String], whose constructor rejects bools.
static func cli_args() -> Dictionary:
	var out := {}
	var argv := OS.get_cmdline_args() + OS.get_cmdline_user_args()
	var index := 0
	while index < argv.size():
		var raw := String(argv[index])
		index += 1
		if not raw.begins_with("--"):
			continue
		var body := raw.substr(2)
		if body.is_empty():
			continue
		var equals := body.find("=")
		if equals != -1:
			out[body.substr(0, equals)] = body.substr(equals + 1)
		elif index < argv.size() and not String(argv[index]).begins_with("--"):
			out[body] = String(argv[index])
			index += 1
		else:
			out[body] = true
	return out
