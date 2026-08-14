class_name MpfSteamCloudBackend
extends MpfSaveBackend
## Steam Cloud remote storage, so saves follow the player between machines.
##
## Falls back to reporting unavailable when GodotSteam is not installed, which
## lets [code]Save.configure({"backend": "auto"})[/code] pick it only when it
## can actually work.

var prefix: String = "mpf_"
var extension: String = ".save"


func id() -> StringName:
	return &"steam_cloud"


func is_available() -> bool:
	return MpfSteam.is_ready()


func read(key: String) -> PackedByteArray:
	return MpfSteam.cloud_read(file_for(key))


func write(key: String, bytes: PackedByteArray) -> Error:
	return OK if MpfSteam.cloud_write(file_for(key), bytes) else FAILED


func exists(key: String) -> bool:
	return MpfSteam.cloud_exists(file_for(key))


func erase(key: String) -> bool:
	return MpfSteam.cloud_delete(file_for(key))


func list() -> PackedStringArray:
	var out := PackedStringArray()
	for file_name: String in MpfSteam.cloud_list():
		if file_name.begins_with(prefix) and file_name.ends_with(extension):
			out.append(file_name.trim_prefix(prefix).trim_suffix(extension))
	return out


func file_for(key: String) -> String:
	return "%s%s%s" % [prefix, key.validate_filename(), extension]
