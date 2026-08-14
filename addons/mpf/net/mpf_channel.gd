class_name MpfChannel
extends RefCounted
## Policy for one named network channel. Registering a channel instead of
## writing [code]@rpc[/code] functions means every message passes the same
## direction, auth, rate and schema checks by construction.

enum Direction { ANY, TO_SERVER, TO_CLIENTS }

var name: StringName = &""
## func(sender_id: int, payload: Variant)
var handler: Callable = Callable()
var reliable: bool = true
var ordered: bool = false
var direction: Direction = Direction.ANY
## Messages per second accepted from one sender. 0 disables the limit.
var rate: float = 30.0
var burst: float = 0.0
## Serialised byte cap. 0 disables the check, which matters for hot channels:
## measuring it costs a full re-serialise of every inbound packet.
var max_bytes: int = 4096
## Cap on entries in a Dictionary or Array payload. 0 disables. This is an O(1)
## check, so it is the cheap way to bound batch channels.
var max_entries: int = 0
var schema: Dictionary = {}
var requires_auth: bool = true
## Framework-owned. Internal names start with `__` and game code cannot
## overwrite them.
var internal: bool = false


static func create(channel_name: StringName, handler_callable: Callable, options: Dictionary = {}) -> MpfChannel:
	var channel := MpfChannel.new()
	channel.name = channel_name
	channel.handler = handler_callable
	channel.reliable = bool(options.get("reliable", true))
	channel.ordered = bool(options.get("ordered", false))
	channel.direction = _parse_direction(options.get("direction", "any"))
	channel.rate = float(options.get("rate", 30.0))
	channel.burst = float(options.get("burst", 0.0))
	channel.max_bytes = int(options.get("max_bytes", 4096))
	channel.max_entries = int(options.get("max_entries", 0))
	channel.schema = options.get("schema", {}) as Dictionary
	channel.requires_auth = bool(options.get("requires_auth", true))
	channel.internal = bool(options.get("internal", false))
	return channel


func accepts_from(sender_is_server: bool) -> bool:
	match direction:
		Direction.TO_SERVER:
			return not sender_is_server
		Direction.TO_CLIENTS:
			return sender_is_server
		_:
			return true


static func _parse_direction(value: Variant) -> Direction:
	if typeof(value) == TYPE_INT:
		return int(value) as Direction
	match String(value).to_lower():
		"to_server", "up":
			return Direction.TO_SERVER
		"to_clients", "down":
			return Direction.TO_CLIENTS
		_:
			return Direction.ANY


func _to_string() -> String:
	return "MpfChannel(%s)" % name
