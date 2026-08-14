extends SceneTree
## Single-process tests for everything that does not need a socket.
##
##     godot --headless --path . --script res://tests/unit_tests.gd
##
## Exits 0 when every assertion passes, 1 otherwise.

var _passed := 0
var _failed := 0


func _initialize() -> void:
	MpfLog.level = MpfLog.Level.SILENT
	_run.call_deferred()


func _run() -> void:
	_test_schema()
	_test_rate()
	_test_ring()
	_test_util()
	_test_codec()
	_test_events()
	_test_profile()
	_test_net_time()
	_test_channel()
	_test_value_types()
	_test_steam()
	await _test_lobby_service()
	print("\n[UNIT] %s  passed=%d failed=%d" % [
		"PASSED" if _failed == 0 else "FAILED", _passed, _failed
	])
	quit(0 if _failed == 0 else 1)


# --- harness ----------------------------------------------------------------

func _group(name: String) -> void:
	print("\n[UNIT] %s" % name)


func _ok(label: String, condition: bool) -> void:
	if condition:
		_passed += 1
		print("  PASS  %s" % label)
	else:
		_failed += 1
		print("  FAIL  %s" % label)


func _eq(label: String, actual: Variant, expected: Variant) -> void:
	if actual == expected:
		_passed += 1
		print("  PASS  %s" % label)
	else:
		_failed += 1
		print("  FAIL  %s  (got %s, expected %s)" % [label, str(actual), str(expected)])


# --- MpfSchema --------------------------------------------------------------

func _test_schema() -> void:
	_group("MpfSchema")
	var schema := {
		"name": TYPE_STRING,
		"count": {"type": TYPE_INT, "min": 1, "max": 99},
		"?note": TYPE_STRING,
	}
	_eq("accepts a valid payload", MpfSchema.validate({"name": "a", "count": 5}, schema), "")
	_ok("rejects a missing required field", MpfSchema.validate({"count": 5}, schema) != "")
	_eq("allows an absent optional field", MpfSchema.validate({"name": "a", "count": 5}, schema), "")
	_ok("rejects the wrong type", MpfSchema.validate({"name": 7, "count": 5}, schema) != "")
	_ok("rejects below minimum", MpfSchema.validate({"name": "a", "count": 0}, schema) != "")
	_ok("rejects above maximum", MpfSchema.validate({"name": "a", "count": 500}, schema) != "")
	_eq("widens int to float", MpfSchema.validate({"v": 3}, {"v": TYPE_FLOAT}), "")
	_eq("accepts String for StringName", MpfSchema.validate({"v": "x"}, {"v": TYPE_STRING_NAME}), "")
	_eq("accepts an array-of spec", MpfSchema.validate({"v": [1, 2]}, {"v": [TYPE_INT]}), "")
	_ok("rejects a bad array element", MpfSchema.validate({"v": [1, "x"]}, {"v": [TYPE_INT]}) != "")
	_eq("accepts a nested schema", MpfSchema.validate({"v": {"a": 1}}, {"v": {"a": TYPE_INT}}), "")
	_ok("rejects a bad nested field", MpfSchema.validate({"v": {"a": "x"}}, {"v": {"a": TYPE_INT}}) != "")
	_ok("rejects an over-long string", MpfSchema.validate(
		{"v": "abcdef"}, {"v": {"type": TYPE_STRING, "max_length": 3}}) != "")
	_ok("rejects a value outside the allow-list", MpfSchema.validate(
		{"v": 9}, {"v": {"type": TYPE_INT, "values": [1, 2]}}) != "")
	_ok("rejects a non-dictionary payload", MpfSchema.validate("nope", schema) != "")
	_eq("an empty schema accepts anything", MpfSchema.validate("anything", {}), "")

	# A payload nested past the guard must be refused rather than recursed into.
	var deep: Dictionary = {"v": 1}
	var deep_schema: Dictionary = {"v": TYPE_INT}
	for i: int in 12:
		deep = {"v": deep}
		deep_schema = {"v": deep_schema}
	_ok("rejects excessive nesting", MpfSchema.validate(deep, deep_schema) != "")


# --- MpfRate ----------------------------------------------------------------

func _test_rate() -> void:
	_group("MpfRate")
	var limiter := MpfRate.new()
	var allowed := 0
	for i: int in 10:
		if limiter.allow("peer", 10.0, 3.0):
			allowed += 1
	_eq("burst caps immediate allowances", allowed, 3)
	_ok("a separate key has its own bucket", limiter.allow("other", 10.0, 3.0))
	limiter.forget("peer")
	_ok("forget resets a bucket", limiter.allow("peer", 10.0, 3.0))
	_ok("rate 0 disables limiting", limiter.allow("unlimited", 0.0, 0.0))
	limiter.clear()
	_ok("clear resets every bucket", limiter.allow("peer", 10.0, 3.0))


# --- MpfRing ----------------------------------------------------------------

func _test_ring() -> void:
	_group("MpfRing")
	var ring := MpfRing.new(3)
	_ok("starts empty", ring.is_empty())
	ring.push(1)
	ring.push(2)
	_eq("size tracks pushes", ring.size(), 2)
	_eq("oldest is the first pushed", ring.oldest(), 1)
	_eq("newest is the last pushed", ring.newest(), 2)
	ring.push(3)
	_ok("reports full at capacity", ring.is_full())
	ring.push(4)
	_eq("stays at capacity after overflow", ring.size(), 3)
	_eq("overflow evicts the oldest", ring.oldest(), 2)
	_eq("to_array is oldest first", ring.to_array(), [2, 3, 4])
	_eq("out of range reads are null", ring.at(99), null)
	ring.clear()
	_ok("clear empties it", ring.is_empty())


# --- MpfUtil ----------------------------------------------------------------

func _test_util() -> void:
	_group("MpfUtil")
	var merged := MpfUtil.deep_merge({"a": {"x": 1, "y": 2}, "b": 1}, {"a": {"y": 9}})
	_eq("deep_merge keeps untouched nested keys", merged["a"]["x"], 1)
	_eq("deep_merge overwrites nested keys", merged["a"]["y"], 9)
	_eq("deep_merge keeps top-level keys", merged["b"], 1)

	var nested := {"a": {"b": {"c": 7}}}
	_eq("dig reads a nested path", MpfUtil.dig(nested, "a/b/c"), 7)
	_eq("dig returns the default when missing", MpfUtil.dig(nested, "a/x/c", "d"), "d")
	_ok("bury creates intermediate levels", MpfUtil.bury(nested, "p/q/r", 3))
	_eq("bury wrote the value", MpfUtil.dig(nested, "p/q/r"), 3)
	_ok("bury reports no change for an identical write", not MpfUtil.bury(nested, "p/q/r", 3))

	_eq("stable_hash is deterministic", MpfUtil.stable_hash("abc"), MpfUtil.stable_hash("abc"))
	_ok("stable_hash is non-negative", MpfUtil.stable_hash("xyz") >= 0)
	_ok("stable_hash separates inputs", MpfUtil.stable_hash("a") != MpfUtil.stable_hash("b"))

	_eq("parse_address splits host and port", MpfUtil.parse_address("1.2.3.4:9999"), ["1.2.3.4", 9999])
	_eq("parse_address applies the default port", MpfUtil.parse_address("1.2.3.4", 27015), ["1.2.3.4", 27015])
	_eq("parse_address accepts a dictionary", MpfUtil.parse_address({"host": "h", "port": 10}), ["h", 10])

	var direction := Vector3(0.3, 0.5, -0.8).normalized()
	var restored := MpfUtil.unpack_direction(MpfUtil.pack_direction(direction))
	_ok("direction survives pack and unpack", restored.distance_to(direction) < 0.01)

	_eq("format_bytes handles bytes", MpfUtil.format_bytes(512), "512 B")
	_ok("format_bytes scales up", MpfUtil.format_bytes(2097152).contains("MiB"))


# --- MpfCodec ---------------------------------------------------------------

func _test_codec() -> void:
	_group("MpfCodec")
	var data := {"coins": 10, "name": "hero", "nested": {"level": 3}}
	var encoded := MpfCodec.encode(data, 2, MpfCodec.Format.JSON)
	var decoded := MpfCodec.decode(encoded)
	_ok("json roundtrip succeeds", bool(decoded["ok"]))
	_eq("json preserves the version", decoded["version"], 2)
	_eq("json preserves values", (decoded["data"] as Dictionary)["coins"], 10)
	_eq("json preserves nesting", MpfUtil.dig(decoded["data"], "nested/level"), 3)

	var binary := MpfCodec.encode({"pos": Vector3(1, 2, 3)}, 1, MpfCodec.Format.BINARY)
	var binary_out := MpfCodec.decode(binary)
	_ok("binary roundtrip succeeds", bool(binary_out["ok"]))
	_eq("binary preserves Godot types", (binary_out["data"] as Dictionary)["pos"], Vector3(1, 2, 3))

	# Tampering must be caught rather than silently loaded.
	var text := encoded.get_string_from_utf8()
	var envelope: Dictionary = JSON.parse_string(text)
	(envelope["data"] as Dictionary)["coins"] = 999999
	var tampered := MpfCodec.decode(JSON.stringify(envelope).to_utf8_buffer())
	_ok("detects a tampered payload", not bool(tampered["ok"]))
	_eq("names the failure", tampered["error"], "checksum mismatch")

	_ok("rejects empty input", not bool(MpfCodec.decode(PackedByteArray())["ok"]))
	_ok("rejects unrelated json", not bool(MpfCodec.decode('{"a":1}'.to_utf8_buffer())["ok"]))


# --- MpfEvents --------------------------------------------------------------

var _bus_hits := 0
var _bus_payload: Variant = null
var _bus_event: StringName = &""


func _test_events() -> void:
	_group("MpfEvents")
	var bus := MpfEvents.new()
	_bus_hits = 0
	bus.on(&"ping", _on_bus_one)
	_eq("emit reaches one listener", bus.emit(&"ping", 5), 1)
	_eq("payload is delivered", _bus_payload, 5)

	bus.off(&"ping", _on_bus_one)
	_eq("off removes the listener", bus.emit(&"ping", 1), 0)

	bus.once(&"solo", _on_bus_one)
	bus.emit(&"solo", 1)
	_eq("once fires then unsubscribes", bus.emit(&"solo", 1), 0)

	bus.on(&"zero", _on_bus_zero)
	_bus_hits = 0
	bus.emit(&"zero")
	_eq("zero-argument callbacks are supported", _bus_hits, 1)

	bus.on(&"two", _on_bus_two)
	bus.emit(&"two", "p")
	_eq("two-argument callbacks receive the event name", _bus_event, &"two")

	_ok("has_listeners reports true", bus.has_listeners(&"two"))
	bus.clear(&"two")
	_ok("clear removes an event", not bus.has_listeners(&"two"))

	# A listener bound to a freed object must not crash the bus.
	var temp := Node.new()
	bus.on(&"dead", Callable(temp, "queue_free"))
	temp.free()
	_eq("listeners on freed objects are pruned", bus.emit(&"dead", null), 0)


func _on_bus_one(payload: Variant) -> void:
	_bus_hits += 1
	_bus_payload = payload


func _on_bus_zero() -> void:
	_bus_hits += 1


func _on_bus_two(_payload: Variant, event: StringName) -> void:
	_bus_event = event


# --- MpfProfile -------------------------------------------------------------

func _test_profile() -> void:
	_group("MpfProfile")
	var profile := MpfProfile.new()
	profile.id = "unit"
	_ok("starts empty", profile.is_empty())
	_ok("set_value reports a change", profile.set_value("stats/kills", 3))
	_eq("reads back a nested path", profile.get_value("stats/kills"), 3)
	_eq("returns the default when missing", profile.get_value("stats/deaths", 0), 0)
	_ok("becomes dirty after a write", profile.dirty)
	_ok("set_value reports no change for the same value", not profile.set_value("stats/kills", 3))
	_eq("add increments", profile.add("stats/kills", 2), 5.0)
	_ok("has finds a written path", profile.has("stats/kills"))
	_ok("erase removes a path", profile.erase("stats/kills"))
	_ok("has is false after erase", not profile.has("stats/kills"))
	profile.merge({"inventory": {"rope": 1}})
	_eq("merge adds nested data", profile.get_value("inventory/rope"), 1)
	profile.replace({"fresh": true})
	_eq("replace swaps everything", profile.get_value("fresh"), true)
	_eq("replace drops old data", profile.get_value("inventory/rope", "gone"), "gone")


# --- MpfNetTime -------------------------------------------------------------

func _test_net_time() -> void:
	_group("MpfNetTime")
	var clock := MpfNetTime.new(8)
	_ok("starts unsynced", not clock.synced)
	clock.bootstrap(MpfNetTime.local_ms() + 5000.0)
	_ok("bootstrap shifts the offset", clock.offset_ms > 4000.0)
	_ok("bootstrap makes the clock usable immediately", clock.synced)
	# The first measured sample replaces the bootstrap guess outright rather
	# than easing toward it, or the estimate would stay wrong for seconds.
	clock.submit(1000.0, 5100.0, 1200.0)
	_ok("the first real sample overrides the bootstrap guess",
		absf(clock.offset_ms - 4000.0) < 1.0)

	var fresh := MpfNetTime.new(8)
	fresh.submit(1000.0, 5100.0, 1200.0)
	_ok("submit marks it synced", fresh.synced)
	_ok("submit records a round trip", fresh.rtt_ms > 0.0)
	# 200ms round trip, server said 5100 at the midpoint, so offset is ~4000.
	_ok("offset is derived from the midpoint", absf(fresh.offset_ms - 4000.0) < 1.0)
	fresh.reset()
	_ok("reset clears the estimate", not fresh.synced and fresh.offset_ms == 0.0)


# --- MpfChannel -------------------------------------------------------------

func _test_channel() -> void:
	_group("MpfChannel")
	var up := MpfChannel.create(&"up", Callable(), {"direction": "to_server"})
	_ok("to_server accepts a client", up.accepts_from(false))
	_ok("to_server rejects the server", not up.accepts_from(true))

	var down := MpfChannel.create(&"down", Callable(), {"direction": "to_clients"})
	_ok("to_clients accepts the server", down.accepts_from(true))
	_ok("to_clients rejects a client", not down.accepts_from(false))

	var any := MpfChannel.create(&"any", Callable(), {})
	_ok("the default direction accepts both", any.accepts_from(true) and any.accepts_from(false))
	_ok("defaults to reliable", any.reliable)
	_ok("defaults to requiring auth", any.requires_auth)
	_eq("carries max_entries", MpfChannel.create(&"b", Callable(), {"max_entries": 32}).max_entries, 32)


# --- Value types ------------------------------------------------------------

func _test_value_types() -> void:
	_group("Value types")
	var peer := MpfPeer.new()
	peer.id = 7
	peer.display_name = "Ann"
	peer.platform_id = "76561190000000000"
	peer.meta = {"team": "red"}
	var peer_copy := MpfPeer.from_dict(peer.to_dict())
	_eq("peer id survives a roundtrip", peer_copy.id, 7)
	_eq("peer name survives a roundtrip", peer_copy.display_name, "Ann")
	_eq("peer platform id stays a string", peer_copy.platform_id, "76561190000000000")
	_eq("peer meta survives a roundtrip", peer_copy.meta["team"], "red")
	_ok("peer 1 is flagged as the server", MpfPeer.from_dict({"id": 1}).is_server)

	var lobby := MpfLobby.new()
	lobby.source = &"lan"
	lobby.address = "10.0.0.5"
	lobby.port = 27015
	lobby.max_players = 4
	lobby.player_count = 4
	_eq("lan lobbies resolve to an address", lobby.connect_target(), "10.0.0.5:27015")
	_ok("reports full", lobby.is_full())
	var steam_lobby := MpfLobby.from_dict({"source": "steam", "owner": "123"})
	_eq("steam lobbies resolve to the owner id", steam_lobby.connect_target(), "123")

	_eq("storage key prefers a verified platform id",
		MpfPeer.storage_key_for("76561190000000000", "tok", "Ann"), "steam:76561190000000000")
	_eq("storage key uses the token when there is no platform id",
		MpfPeer.storage_key_for("", "abc123", "Ann"), "tok:abc123")
	_eq("storage key falls back to a guest key",
		MpfPeer.storage_key_for("", "", "Ann"), "guest:ann")
	# The whole point: two players cannot collide just by picking the same name.
	_ok("different tokens give different keys",
		MpfPeer.storage_key_for("", "aaa", "Ann") != MpfPeer.storage_key_for("", "bbb", "Ann"))
	_ok("a token beats a shared name",
		MpfPeer.storage_key_for("", "aaa", "Ann") != MpfPeer.storage_key_for("", "", "Ann"))


# --- Steam ------------------------------------------------------------------
#
# GodotSteam is a native extension that cannot be installed in CI, which is why
# this layer sat at zero coverage. MpfSteam resolves everything by name through
# Engine.get_singleton, so a mock registered under that name is what gets
# called. This proves MPF talks to Steam correctly; it cannot prove Steam
# answers the way we expect.

func _test_steam() -> void:
	_group("MpfSteam (mocked)")
	_ok("reports unavailable with no singleton", not MpfSteam.is_available())

	var mock := MockSteam.install()
	_ok("detects the singleton", MpfSteam.is_available())
	_ok("initialises", MpfSteam.initialize(480))
	_ok("the mock saw the init", mock.initialised)
	_eq("reads the steam id", MpfSteam.steam_id(), MockSteam.SELF_ID)
	_eq("reads the persona name", MpfSteam.persona_name(), "MockPlayer")

	MpfSteam.run_callbacks()
	_eq("pumps callbacks", mock.callbacks_run, 1)

	MpfSteam.create_lobby(MpfSteam.LOBBY_PUBLIC, 4)
	var lobby_id: int = mock.lobbies.keys()[0]
	MpfSteam.set_lobby_data(lobby_id, "name", "Camp")
	_eq("writes and reads lobby data", MpfSteam.get_lobby_data(lobby_id, "name"), "Camp")
	_eq("reads the lobby owner", MpfSteam.lobby_owner(lobby_id), MockSteam.SELF_ID)
	_eq("reads the member count", MpfSteam.lobby_member_count(lobby_id), 1)

	MpfSteam.filter_lobbies_by("mpf", "1", 0)
	_ok("passes list filters through", mock.last_filters.has("mpf"))
	MpfSteam.limit_lobby_results(25)
	_eq("passes the result limit", mock.last_filters.get("_limit"), 25)

	MpfSteam.open_invite_overlay(lobby_id)
	_eq("opens the invite overlay", mock.overlay_invites.size(), 1)

	var payload := "hello".to_utf8_buffer()
	_ok("writes to the cloud", MpfSteam.cloud_write("save.dat", payload))
	_ok("sees the cloud file", MpfSteam.cloud_exists("save.dat"))
	_eq("reads the cloud file back", MpfSteam.cloud_read("save.dat"), payload)
	_ok("lists cloud files", MpfSteam.cloud_list().has("save.dat"))
	_ok("deletes cloud files", MpfSteam.cloud_delete("save.dat"))
	_ok("the deleted file is gone", not MpfSteam.cloud_exists("save.dat"))
	_eq("reading a missing file is empty", MpfSteam.cloud_read("nope.dat"), PackedByteArray())

	var backend := MpfSteamCloudBackend.new()
	_ok("the cloud backend reports available", backend.is_available())
	_eq("the backend writes", backend.write("slot1", payload), OK)
	_eq("the backend reads back", backend.read("slot1"), payload)
	_ok("the backend lists profiles", backend.list().has("slot1"))
	_ok("the backend erases", backend.erase("slot1"))

	# Gated off, so nothing selects an untested transport by accident.
	_ok("the transport stays disabled without the flag", not MpfSteamTransport.enabled())
	var transport := MpfSteamTransport.new()
	_ok("a disabled transport reports unavailable", not transport.is_available())

	MockSteam.uninstall()
	_ok("uninstalls cleanly", not MpfSteam.is_available())


func _test_lobby_service() -> void:
	_group("MpfLobbyService (mocked)")
	var mock := MockSteam.install()
	MpfSteam.initialize(480)
	var service := MpfLobbyService.new()
	root.add_child(service)

	var lobby := MpfLobby.new()
	lobby.name = "Camp"
	lobby.host_name = "MockPlayer"
	lobby.max_players = 4
	lobby.game_version = "1.0"
	lobby.data = {"visibility": "public"}
	service.advertise(lobby, true)
	# createLobby answers on a callback, never inline, so let the signal land.
	await process_frame
	await process_frame

	_ok("created a steam lobby", not mock.lobbies.is_empty())
	var created_id: int = mock.lobbies.keys()[0]
	_eq("published the lobby name", MpfSteam.get_lobby_data(created_id, "name"), "Camp")
	_eq("tagged the lobby as ours", MpfSteam.get_lobby_data(created_id, "mpf"), "1")
	_eq("published the version", MpfSteam.get_lobby_data(created_id, "version"), "1.0")
	_eq("reports the current lobby", service.current_lobby_id(), str(created_id))

	service.update_advertisement(3)
	_eq("republishes the player count", MpfSteam.get_lobby_data(created_id, "players"), "3")

	# Appended rather than reassigned: a GDScript lambda captures locals by
	# value, so `found = result` inside it would never reach this scope.
	var found: Array = []
	service.list_updated.connect(func(result: Array[MpfLobby]) -> void: found.append_array(result))
	service.refresh(true)
	await process_frame
	await process_frame
	_ok("discovers lobbies", found.size() >= 1)
	if found.size() >= 1:
		var first: MpfLobby = found[0]
		_eq("discovered lobby carries its name", first.name, "Camp")
		_eq("discovered lobby resolves to its owner", first.connect_target(), str(MockSteam.SELF_ID))

	_ok("invites through the overlay", service.invite())
	service.stop_advertising()

	root.remove_child(service)
	service.queue_free()
	MockSteam.uninstall()
