extends Node
## Save autoload. Profiles, versioned migrations, pluggable storage and
## per-player persistence. Registered by the plugin.

signal profile_loaded(profile: MpfProfile)
signal profile_saved(profile: MpfProfile)
signal save_failed(profile_id: String, reason: String)

var backend: MpfSaveBackend = null
var format: MpfCodec.Format = MpfCodec.Format.JSON
## Current schema version. Raise it when you add a migration.
var version: int = 1
var players: MpfPlayerDataService = null
## Seconds between automatic writes of changed profiles. 0 disables.
var autosave_interval: float = 30.0

var _profiles: Dictionary = {}
var _migrations: Dictionary = {}
var _timer: float = 0.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	configure()
	players = MpfPlayerDataService.new()
	players.name = "Players"
	add_child(players)


func _process(delta: float) -> void:
	if autosave_interval <= 0.0:
		return
	_timer += delta
	if _timer < autosave_interval:
		return
	_timer = 0.0
	flush_dirty()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_CRASH:
		flush_dirty()


## Options: `backend` ("auto" | "local" | "steam_cloud"), `directory`,
## `encryption_key`, `format` ("json" | "binary"), `version`,
## `autosave_interval`.
func configure(options: Dictionary = {}) -> void:
	var merged := {
		"backend": String(ProjectSettings.get_setting("mpf/save/backend", "auto")),
		"directory": String(ProjectSettings.get_setting("mpf/save/directory", "user://saves")),
		"format": String(ProjectSettings.get_setting("mpf/save/format", "json")),
		"version": int(ProjectSettings.get_setting("mpf/save/version", 1)),
		"encryption_key": "",
		"autosave_interval": 30.0,
	}
	merged.merge(options, true)
	version = int(merged["version"])
	format = MpfCodec.Format.BINARY if String(merged["format"]) == "binary" else MpfCodec.Format.JSON
	autosave_interval = float(merged["autosave_interval"])
	backend = _make_backend(String(merged["backend"]), merged)
	MpfLog.info("save", "Configured", {"backend": String(backend.id()), "version": version})


## Opens a save slot, reading it from storage the first time. Repeated calls
## return the same live object.
func open(profile_id: String = "default") -> MpfProfile:
	if _profiles.has(profile_id):
		return _profiles[profile_id]
	var profile := MpfProfile.new()
	profile.id = profile_id
	profile.attach(self)
	read_into(profile)
	_profiles[profile_id] = profile
	profile_loaded.emit(profile)
	return profile


## Every profile currently open in memory.
func open_profiles() -> Array[MpfProfile]:
	var out: Array[MpfProfile] = []
	for profile: MpfProfile in _profiles.values():
		out.append(profile)
	return out


## Writes a profile immediately. Prefer [method MpfProfile.save].
func write(profile: MpfProfile) -> Error:
	if backend == null:
		return ERR_UNCONFIGURED
	var bytes := MpfCodec.encode(profile.data(), version, format)
	var result := backend.write(profile.id, bytes)
	if result != OK:
		MpfLog.error("save", "Write failed", {"profile": profile.id, "error": error_string(result)})
		save_failed.emit(profile.id, error_string(result))
		return result
	profile.dirty = false
	profile.version = version
	profile.saved_at = int(Time.get_unix_time_from_system())
	profile_saved.emit(profile)
	return OK


## Reads storage into an existing profile, running any pending migrations.
func read_into(profile: MpfProfile) -> Error:
	if backend == null:
		return ERR_UNCONFIGURED
	var bytes := backend.read(profile.id)
	if bytes.is_empty():
		profile.version = version
		profile.dirty = false
		return OK
	var decoded := MpfCodec.decode(bytes)
	if not bool(decoded["ok"]):
		MpfLog.error("save", "Could not decode save", {"profile": profile.id, "error": decoded["error"]})
		save_failed.emit(profile.id, String(decoded["error"]))
		return ERR_FILE_CORRUPT
	var data: Dictionary = decoded["data"]
	var from_version := int(decoded["version"])
	if from_version < version:
		data = migrate(data, from_version)
	profile.replace(data)
	profile.version = version
	profile.saved_at = int(decoded["saved_at"])
	profile.dirty = false
	return OK


func flush_dirty() -> void:
	for profile: MpfProfile in _profiles.values():
		if profile.dirty:
			write(profile)


func save_all() -> void:
	for profile: MpfProfile in _profiles.values():
		write(profile)
	if players != null:
		players.save_all()


## Drops a profile from memory, writing it first if it changed.
func close(profile_id: String) -> void:
	var profile: MpfProfile = _profiles.get(profile_id)
	if profile == null:
		return
	if profile.dirty:
		write(profile)
	_profiles.erase(profile_id)


func delete(profile_id: String) -> bool:
	_profiles.erase(profile_id)
	return backend != null and backend.erase(profile_id)


func exists(profile_id: String) -> bool:
	return backend != null and backend.exists(profile_id)


func list() -> PackedStringArray:
	return backend.list() if backend != null else PackedStringArray()


## Registers a transform that upgrades data to [param to_version].
## `func(data: Dictionary) -> Dictionary`.
func register_migration(to_version: int, transform: Callable) -> void:
	_migrations[to_version] = transform


## Runs every migration between [param from_version] and [member version].
func migrate(data: Dictionary, from_version: int) -> Dictionary:
	var result := data
	for step: int in range(from_version + 1, version + 1):
		var transform: Callable = _migrations.get(step, Callable())
		if not transform.is_valid():
			continue
		result = transform.call(result) as Dictionary
		MpfLog.info("save", "Migrated save", {"to": step})
	return result


func _make_backend(choice: String, options: Dictionary) -> MpfSaveBackend:
	if choice == "steam_cloud" or (choice == "auto" and MpfSteam.is_available()):
		var cloud := MpfSteamCloudBackend.new()
		if cloud.is_available():
			return cloud
	var local := MpfLocalBackend.new()
	local.directory = String(options.get("directory", "user://saves"))
	local.encryption_key = String(options.get("encryption_key", ""))
	return local
