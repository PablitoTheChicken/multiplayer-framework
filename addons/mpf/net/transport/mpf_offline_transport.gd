class_name MpfOfflineTransport
extends MpfTransport
## Single-player. The local machine is the server and the only peer, so the
## same gameplay scripts run unchanged without a network.


func id() -> StringName:
	return &"offline"


func is_available() -> bool:
	return true


func create_server(_options: Dictionary) -> MultiplayerPeer:
	return OfflineMultiplayerPeer.new()


func create_client(_target: Variant, _options: Dictionary) -> MultiplayerPeer:
	_fail("the offline transport cannot connect to a remote host")
	return null


func describe(_target: Variant) -> String:
	return "offline"
