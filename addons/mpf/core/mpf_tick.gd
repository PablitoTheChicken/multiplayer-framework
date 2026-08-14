class_name MpfTick
extends Node
## Fixed-rate clock driving every timed network send, so bandwidth stays
## independent of frame rate.

signal tick(delta: float, index: int)

var rate: int = 30:
	set(value):
		rate = maxi(1, value)
		_step = 1.0 / float(rate)

var index: int = 0
var max_catch_up: int = 4

var step: float:
	get:
		return _step

var _step: float = 1.0 / 30.0
var _accumulator: float = 0.0


func _ready() -> void:
	process_priority = -100


func _physics_process(delta: float) -> void:
	_accumulator += delta
	var budget := max_catch_up
	while _accumulator >= _step and budget > 0:
		_accumulator -= _step
		index += 1
		budget -= 1
		tick.emit(_step, index)
	if _accumulator >= _step:
		_accumulator = 0.0 # Drop the backlog rather than spiral on it.


func elapsed() -> float:
	return float(index) * _step


## True every [param n]-th tick, for running a system at a fraction of the rate.
func every(n: int) -> bool:
	return n > 0 and index % n == 0


func reset() -> void:
	index = 0
	_accumulator = 0.0
