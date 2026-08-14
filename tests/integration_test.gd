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
var _results: Array[Dictionary] = []
var _elapsed := 0.0
var _done := false

var _entity: Node = null
var _client_ready := false
var _moved := false

var _saw_entity := false
var _saw_state := false
var _saw_move := false


func _ready() -> void:
	world.register_scene(&"probe", ENTITY_SCENE)
	_role = str(MpfUtil.cli_args().get("test", "host"))
	print("[TEST] role=%s starting" % _role)
	if _role == "host":
		Net.set_local_name("TestHost")
		Net.peer_ready.connect(_on_peer_ready)
		Net.host({"transport": "enet", "port": PORT, "advertise": false})
	else:
		Net.set_local_name("TestClient")
		Net.join("127.0.0.1:%d" % PORT)


func _process(delta: float) -> void:
	if _done:
		return
	_elapsed += delta
	if _elapsed > TIMEOUT:
		_record("finished before timeout", false)
		_finish()
		return
	if _role == "host":
		_tick_host()
	else:
		_tick_client()


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
		return
	# Move and mutate state only once the client is definitely present, so the
	# client is testing replication rather than late-join catch-up.
	if not _moved and _elapsed > MOVE_AT:
		_moved = true
		(_entity as Node3D).global_position = TARGET
		_state_of(_entity).set_value(&"phase", 42)
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
	if _saw_state and _saw_move:
		_record("client clock synced with the server", Net.time.synced)
		_finish()


func _find_probe() -> Node:
	for node: Node in world.entities():
		if _state_of(node) != null:
			return node
	return null


static func _state_of(node: Node) -> MpfNetState:
	return MpfUtil.find_child_of_type(node, MpfNetState) as MpfNetState


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
	var expected := 4 if _role == "client" else 2
	if _results.size() < expected:
		print("[TEST] FAIL  only %d of %d checks ran" % [_results.size(), expected])
		failures += 1
	print("[TEST] %s role=%s checks=%d failures=%d" % [
		"PASSED" if failures == 0 else "FAILED", _role, _results.size(), failures
	])
	get_tree().quit(0 if failures == 0 else 1)
