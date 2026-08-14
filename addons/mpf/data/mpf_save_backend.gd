class_name MpfSaveBackend
extends RefCounted
## Base class for somewhere save bytes can live. The save layer only ever sees
## opaque byte blobs, so swapping local files for Steam Cloud changes nothing
## above this line.


func id() -> StringName:
	return &"none"


func is_available() -> bool:
	return false


func read(_key: String) -> PackedByteArray:
	return PackedByteArray()


func write(_key: String, _bytes: PackedByteArray) -> Error:
	return ERR_UNAVAILABLE


func exists(_key: String) -> bool:
	return false


func erase(_key: String) -> bool:
	return false


func list() -> PackedStringArray:
	return PackedStringArray()
