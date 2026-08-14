class_name MpfEnetTransport
extends MpfTransport
## UDP transport over ENet. Backs both listen servers and dedicated servers:
## a dedicated build is just a host with no local player, reachable by
## address and port.

const DEFAULT_PORT := 27015


func id() -> StringName:
	return &"enet"


func is_available() -> bool:
	return true


func create_server(options: Dictionary) -> MultiplayerPeer:
	var port := int(options.get("port", DEFAULT_PORT))
	var max_players := int(options.get("max_players", 16))
	var peer := ENetMultiplayerPeer.new()
	var bind_address := String(options.get("bind_address", "*"))
	if bind_address != "*":
		peer.set_bind_ip(bind_address)
	var err := peer.create_server(port, max_players)
	if err != OK:
		_fail("could not bind port %d (%s)" % [port, error_string(err)])
		return null
	_configure(peer, options)
	MpfLog.info("net", "ENet server listening", {"port": port, "max_players": max_players})
	return peer


func create_client(target: Variant, options: Dictionary) -> MultiplayerPeer:
	var address := MpfUtil.parse_address(target, int(options.get("port", DEFAULT_PORT)))
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(String(address[0]), int(address[1]))
	if err != OK:
		_fail("could not reach %s:%d (%s)" % [address[0], address[1], error_string(err)])
		return null
	_configure(peer, options)
	MpfLog.info("net", "ENet client connecting", {"host": address[0], "port": address[1]})
	return peer


func describe(target: Variant) -> String:
	var address := MpfUtil.parse_address(target, DEFAULT_PORT)
	return "%s:%d" % [address[0], address[1]]


func _configure(peer: ENetMultiplayerPeer, options: Dictionary) -> void:
	var host := peer.host
	if host == null:
		return
	if bool(options.get("compression", true)):
		host.compress(ENetConnection.COMPRESS_RANGE_CODER)
