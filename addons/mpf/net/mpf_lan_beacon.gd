class_name MpfLanBeacon
extends Node
## UDP broadcast discovery, so players on the same network can find a host
## without Steam or a master server.

signal list_changed(lobbies: Array[MpfLobby])

enum Mode { IDLE, ADVERTISING, LISTENING }

const DEFAULT_PORT := 27016
const BROADCAST_INTERVAL := 1.0
const ENTRY_TTL := 4.0
const MAX_PACKET_BYTES := 1024

var port: int = DEFAULT_PORT
var mode: Mode = Mode.IDLE

var _socket: PacketPeerUDP = null
var _payload: Dictionary = {}
var _timer: float = 0.0
var _entries: Dictionary = {}


func _ready() -> void:
	set_process(false)


## Starts broadcasting [param lobby] on the local network.
func advertise(lobby: MpfLobby) -> void:
	stop()
	_payload = lobby.to_dict()
	_socket = PacketPeerUDP.new()
	_socket.set_broadcast_enabled(true)
	_socket.set_dest_address("255.255.255.255", port)
	mode = Mode.ADVERTISING
	_timer = BROADCAST_INTERVAL
	set_process(true)


## Updates the advertised payload without restarting the broadcast.
func update_advertisement(lobby: MpfLobby) -> void:
	if mode == Mode.ADVERTISING:
		_payload = lobby.to_dict()


## Starts collecting broadcasts from hosts on the local network.
func listen() -> bool:
	stop()
	_socket = PacketPeerUDP.new()
	var err := _socket.bind(port, "*", 8192)
	if err != OK:
		MpfLog.warn("net", "LAN discovery could not bind", {"port": port, "error": error_string(err)})
		_socket = null
		return false
	mode = Mode.LISTENING
	set_process(true)
	return true


func stop() -> void:
	if _socket != null:
		_socket.close()
		_socket = null
	mode = Mode.IDLE
	set_process(false)


func lobbies() -> Array[MpfLobby]:
	var out: Array[MpfLobby] = []
	for entry: Dictionary in _entries.values():
		out.append(entry["lobby"])
	return out


func clear() -> void:
	_entries.clear()
	list_changed.emit(lobbies())


func _process(delta: float) -> void:
	if _socket == null:
		return
	if mode == Mode.ADVERTISING:
		_timer += delta
		if _timer >= BROADCAST_INTERVAL:
			_timer = 0.0
			_socket.put_packet(JSON.stringify(_payload).to_utf8_buffer())
		return
	_receive()
	_expire()


func _receive() -> void:
	var dirty := false
	while _socket.get_available_packet_count() > 0:
		var raw := _socket.get_packet()
		if raw.size() > MAX_PACKET_BYTES:
			continue
		var parsed: Variant = JSON.parse_string(raw.get_string_from_utf8())
		if typeof(parsed) != TYPE_DICTIONARY:
			continue
		var lobby := MpfLobby.from_dict(parsed)
		lobby.source = &"lan"
		lobby.address = _socket.get_packet_ip()
		if lobby.id == "":
			lobby.id = "%s:%d" % [lobby.address, lobby.port]
		_entries[lobby.id] = {"lobby": lobby, "seen": Time.get_ticks_msec()}
		dirty = true
	if dirty:
		list_changed.emit(lobbies())


func _expire() -> void:
	var now := Time.get_ticks_msec()
	var dropped := false
	for key: Variant in _entries.keys():
		if now - int(_entries[key]["seen"]) > int(ENTRY_TTL * 1000.0):
			_entries.erase(key)
			dropped = true
	if dropped:
		list_changed.emit(lobbies())
