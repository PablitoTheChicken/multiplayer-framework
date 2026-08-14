class_name MpfTransport
extends RefCounted
## Base class for a way of moving packets. Subclasses hand back a configured
## [MultiplayerPeer]; everything above this layer is transport-agnostic.

signal failed(reason: String)

var last_error: String = ""


func id() -> StringName:
	return &"none"


func is_available() -> bool:
	return false


## True when this transport can list and join lobbies rather than raw addresses.
func supports_lobbies() -> bool:
	return false


func create_server(_options: Dictionary) -> MultiplayerPeer:
	return null


func create_client(_target: Variant, _options: Dictionary) -> MultiplayerPeer:
	return null


func poll(_delta: float) -> void:
	pass


func shutdown() -> void:
	pass


func describe(target: Variant) -> String:
	return str(target)


func _fail(reason: String) -> void:
	last_error = reason
	MpfLog.error("net", "Transport failed", {"transport": String(id()), "reason": reason})
	failed.emit(reason)
