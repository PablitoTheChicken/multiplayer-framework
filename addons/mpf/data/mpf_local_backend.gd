class_name MpfLocalBackend
extends MpfSaveBackend
## Save files under [code]user://[/code].
##
## Writes go to a temporary file that is renamed into place, and the previous
## file is kept as [code].bak[/code]. A crash or power cut during a save can
## therefore never leave the player with nothing.

var directory: String = "user://saves"
var extension: String = ".save"
## Non-empty enables Godot's built-in file encryption. Stops casual editing,
## not a determined attacker with the binary in hand.
var encryption_key: String = ""


func id() -> StringName:
	return &"local"


func is_available() -> bool:
	return true


func read(key: String) -> PackedByteArray:
	var path := path_for(key)
	if not FileAccess.file_exists(path):
		var backup := path + ".bak"
		if not FileAccess.file_exists(backup):
			return PackedByteArray()
		MpfLog.warn("save", "Main file missing, reading backup", {"key": key})
		path = backup
	var file := _open(path, FileAccess.READ)
	if file == null:
		MpfLog.error("save", "Could not read save", {"key": key, "error": error_string(FileAccess.get_open_error())})
		return PackedByteArray()
	var bytes := file.get_buffer(file.get_length())
	file.close()
	return bytes


func write(key: String, bytes: PackedByteArray) -> Error:
	var made := DirAccess.make_dir_recursive_absolute(directory)
	if made != OK and made != ERR_ALREADY_EXISTS:
		return made
	var final := path_for(key)
	var temp := final + ".tmp"
	var file := _open(temp, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_buffer(bytes)
	file.close()
	if FileAccess.file_exists(final):
		var backup := final + ".bak"
		if FileAccess.file_exists(backup):
			DirAccess.remove_absolute(backup)
		var moved := DirAccess.rename_absolute(final, backup)
		if moved != OK:
			return moved
	return DirAccess.rename_absolute(temp, final)


func exists(key: String) -> bool:
	return FileAccess.file_exists(path_for(key))


func erase(key: String) -> bool:
	var path := path_for(key)
	var removed := false
	for candidate: String in [path, path + ".bak", path + ".tmp"]:
		if FileAccess.file_exists(candidate):
			DirAccess.remove_absolute(candidate)
			removed = true
	return removed


func list() -> PackedStringArray:
	var out := PackedStringArray()
	if not DirAccess.dir_exists_absolute(directory):
		return out
	for file_name: String in DirAccess.get_files_at(directory):
		if file_name.ends_with(extension):
			out.append(file_name.trim_suffix(extension))
	return out


func path_for(key: String) -> String:
	return "%s/%s%s" % [directory, key.validate_filename(), extension]


func _open(path: String, mode: FileAccess.ModeFlags) -> FileAccess:
	if encryption_key != "":
		return FileAccess.open_encrypted_with_pass(path, mode, encryption_key)
	return FileAccess.open(path, mode)
