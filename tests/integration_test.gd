extends Node3D
## Cross-process integration test for the replication path.
##
## Two instances of this scene talk to each other over a real socket, which is
## the only way to exercise the parts that cannot be reached in a single
## process: the handshake, batched state and transform replication, clock sync
## and late-join delivery.
##
##     godot --headless --path . -- --test=host
##     godot --headless --path . -- --test=client
##
## Each half prints PASS/FAIL lines and exits 0 or 1. Use tests/run_tests.ps1
## to drive both.

const PORT := 27099
const ENTITY_SCENE := preload("res://tests/test_entity.tscn")
const PHYSICS_SCENE := preload("res://tests/test_physics_entity.tscn")
const START := Vector3(0.0, 1.0, 0.0)
const TARGET := Vector3(12.0, 3.0, -7.0)
## Generous: the client renders interpolated and slightly behind, so exact
## equality would be testing the wrong thing.
const TOLERANCE := 0.75
const TIMEOUT := 30.0
const MOVE_AT := 6.0
const HOST_FINISH_AT := 18.0

@onready var world: MpfNetWorld = $NetWorld

var _role := "host"
var _scenario := "core"
var _results: Array[Dictionary] = []
var _channel_hits := 0
var _gate_hits := 0
var _gate_rejections: Array[String] = []
var _sent_probe := false
var _requested_gate := false
var _elapsed := 0.0
var _done := false

var _entity: Node = null
var _physics: Node = null
var _client_ready := false
var _moved := false

var _saw_entity := false
var _saw_state := false
var _saw_move := false
var _saw_physics_frozen := false
var _saw_physics_move := false


func _ready() -> void:
	world.register_scene(&"probe", ENTITY_SCENE)
	world.register_scene(&"physics_probe", PHYSICS_SCENE)
	var args := MpfUtil.cli_args()
	_role = str(args.get("test", "host"))
	_scenario = str(args.get("scenario", "core"))
	print("[TEST] role=%s scenario=%s starting" % [_role, _scenario])
	# Registered on both sides: the schema is what the server enforces, and the
	# client needs the channel to exist in order to send on it at all.
	Net.register_channel(&"probe_chan", _on_probe_channel, {
		"direction": "to_server",
		"schema": {"n": TYPE_INT},
	})
	if _role == "host":
		Net.set_local_name("TestHost")
		Net.peer_ready.connect(_on_peer_ready)
		Net.host({"transport": "enet", "port": PORT, "advertise": false})
	else:
		Net.set_local_name("TestClient")
		Net.join("127.0.0.1:%d" % PORT)


func _on_probe_channel(_sender: int, _payload: Dictionary) -> void:
	_channel_hits += 1


func _process(delta: float) -> void:
	if _done:
		return
	_elapsed += delta
	if _elapsed > TIMEOUT:
		_record("finished before timeout", false)
		_finish()
		return
	match _scenario:
		"late_join":
			_tick_late_join()
		"rejection":
			_tick_rejection()
		_:
			if _role == "host":
				_tick_host()
			else:
				_tick_client()


# --- scenario: late_join ----------------------------------------------------
#
# The host changes state and moves the entity BEFORE anyone connects. A joiner
# must still arrive at the current values, which is what force_sync on
# peer_joined exists for. Regression cover for state that only replicated to
# peers who happened to be present when it changed.

func _tick_late_join() -> void:
	if _role == "host":
		if _entity == null:
			_entity = world.spawn(&"probe", {}, 1)
			_record("host spawned before anyone joined", _entity != null)
			if _entity == null:
				_finish()
				return
			(_entity as Node3D).global_position = TARGET
			_state_of(_entity).define(&"phase", 1)
			_state_of(_entity).set_value(&"phase", 42)
			return
		if _elapsed > HOST_FINISH_AT:
			_record("host saw the late joiner arrive", _client_ready)
			_finish()
		return
	var probe := _find_probe()
	if probe == null:
		return
	var state := _state_of(probe)
	if state == null:
		return
	if not _saw_state and int(state.get_value(&"phase", 0)) == 42:
		_saw_state = true
		_record("late joiner received state changed before it connected", true)
	if not _saw_move and (probe as Node3D).global_position.distance_to(TARGET) < TOLERANCE:
		_saw_move = true
		_record("late joiner received the current transform", true)
	if _saw_state and _saw_move:
		_finish()


# --- scenario: rejection ----------------------------------------------------
#
# Everything the server is supposed to refuse. These paths were written but
# never exercised, which is exactly where security bugs hide.

func _tick_rejection() -> void:
	if _role == "host":
		if _entity == null:
			_entity = world.spawn(&"probe", {}, 1)
			if _entity == null:
				_record("host spawned the gate entity", false)
				_finish()
				return
			_gate_of(_entity).performed.connect(func(_peer: int, _p: Dictionary) -> void:
				_gate_hits += 1)
			return
		if _elapsed > HOST_FINISH_AT:
			# One valid message accepted, one schema violation dropped.
			_record("server accepted the well-formed message", _channel_hits == 1)
			_record("server dropped the schema violation", _channel_hits < 2)
			# One request performed, the immediate repeat refused by cooldown.
			_record("server performed the first request", _gate_hits == 1)
			_record("server refused the repeat request", _gate_hits < 2)
			_finish()
		return

	var probe := _find_probe()
	if probe == null:
		return
	if not _sent_probe:
		_sent_probe = true
		Net.send_to_server(&"probe_chan", {"n": 1})
		Net.send_to_server(&"probe_chan", {"n": "not an int"})
		return
	if not _requested_gate:
		_requested_gate = true
		var gate := _gate_of(probe)
		gate.rejected.connect(func(reason: String) -> void: _gate_rejections.append(reason))
		gate.request({})
		gate.request({})
		return
	if _elapsed > 12.0:
		_record("client was told why its request was refused", _gate_rejections.size() >= 1)
		_record("the refusal names the cooldown",
			_gate_rejections.size() > 0 and _gate_rejections[0].contains("cooldown"))
		_finish()


func _on_peer_ready(peer: MpfPeer) -> void:
	if peer.id != Net.local_id():
		_client_ready = true


func _tick_host() -> void:
	if not _client_ready:
		return
	if _entity == null:
		_entity = world.spawn(&"probe", {}, 1)
		_record("host spawned an entity", _entity != null)
		if _entity == null:
			_finish()
			return
		(_entity as Node3D).global_position = START
		_state_of(_entity).define(&"phase", 1)
		_physics = world.spawn(&"physics_probe", {}, 1)
		_record("host spawned a physics body", _physics != null)
		if _physics != null:
			(_physics as Node3D).global_position = Vector3(0.0, 5.0, 0.0)
		return
	# Move and mutate state only once the client is definitely present, so the
	# client is testing replication rather than late-join catch-up.
	if not _moved and _elapsed > MOVE_AT:
		_moved = true
		(_entity as Node3D).global_position = TARGET
		_state_of(_entity).set_value(&"phase", 42)
		# Push the body through the framework so the impulse is applied where
		# the simulation actually lives.
		var rigid := MpfUtil.find_child_of_type(_physics, MpfNetRigidBody) as MpfNetRigidBody
		_record("host body is the simulating peer", rigid != null and rigid.is_simulating())
		if rigid != null:
			rigid.push(Vector3(6.0, 0.0, 0.0))
		return
	if _moved and _elapsed > HOST_FINISH_AT:
		_record("host completed the handshake with a client", _client_ready)
		_finish()


func _tick_client() -> void:
	var probe := _find_probe()
	if probe == null:
		return
	if not _saw_entity:
		_saw_entity = true
		_record("client received the spawned entity", true)
	var state := _state_of(probe)
	if state == null:
		return
	if not _saw_state and int(state.get_value(&"phase", 0)) == 42:
		_saw_state = true
		_record("client received replicated state over the wire", true)
	if not _saw_move and (probe as Node3D).global_position.distance_to(TARGET) < TOLERANCE:
		_saw_move = true
		_record("client received replicated transform over the wire", true)
	var body := _find_physics_probe()
	if body != null:
		if not _saw_physics_frozen:
			_saw_physics_frozen = true
			# The whole point of MpfNetRigidBody: a non-authoritative copy must
			# not be simulating, or the solver fights the replicated transform.
			_record("client copy of the physics body is frozen", bool(body.get("freeze")))
		if not _saw_physics_move and (body as Node3D).global_position.x > 1.0:
			_saw_physics_move = true
			_record("client received physics motion from a server impulse", true)
	if _saw_state and _saw_move and _saw_physics_frozen and _saw_physics_move:
		_record("client clock synced with the server", Net.time.synced)
		_finish()


func _find_probe() -> Node:
	for node: Node in world.entities():
		if _state_of(node) != null:
			return node
	return null


func _find_physics_probe() -> Node:
	for node: Node in world.entities():
		if node is RigidBody3D:
			return node
	return null


static func _state_of(node: Node) -> MpfNetState:
	return MpfUtil.find_child_of_type(node, MpfNetState) as MpfNetState


static func _gate_of(node: Node) -> MpfAction:
	return MpfUtil.find_child_of_type(node, MpfAction) as MpfAction


## How many assertions this half must produce. A scenario that silently ran
## fewer checks than expected has failed, not passed.
func _expected_checks() -> int:
	match _scenario:
		"late_join":
			return 2
		"rejection":
			return 2 if _role == "client" else 4
		_:
			return 6 if _role == "client" else 4


func _record(label: String, ok: bool) -> void:
	_results.append({"label": label, "ok": ok})
	print("[TEST] %s  %s" % ["PASS" if ok else "FAIL", label])


func _finish() -> void:
	if _done:
		return
	_done = true
	var failures := 0
	for result: Dictionary in _results:
		if not bool(result["ok"]):
			failures += 1
	# A check that never ran is a failure, not a pass by omission.
	var expected := _expected_checks()
	if _results.size() < expected:
		print("[TEST] FAIL  only %d of %d checks ran" % [_results.size(), expected])
		failures += 1
	print("[TEST] %s role=%s checks=%d failures=%d" % [
		"PASSED" if failures == 0 else "FAILED", _role, _results.size(), failures
	])
	get_tree().quit(0 if failures == 0 else 1)
