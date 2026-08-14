class_name MpfRing
extends RefCounted
## Fixed-capacity circular buffer. Pushing past capacity evicts the oldest entry.

var _items: Array = []
var _capacity: int = 0
var _head: int = 0
var _size: int = 0


func _init(capacity: int = 32) -> void:
	_capacity = maxi(1, capacity)
	_items.resize(_capacity)


func push(value: Variant) -> void:
	_items[_head] = value
	_head = (_head + 1) % _capacity
	_size = mini(_size + 1, _capacity)


## Entry at [param index], where 0 is the oldest retained entry.
func at(index: int) -> Variant:
	if index < 0 or index >= _size:
		return null
	var start := (_head - _size + _capacity) % _capacity
	return _items[(start + index) % _capacity]


func newest() -> Variant:
	return at(_size - 1)


func oldest() -> Variant:
	return at(0)


func size() -> int:
	return _size


func capacity() -> int:
	return _capacity


func is_empty() -> bool:
	return _size == 0


func is_full() -> bool:
	return _size == _capacity


func to_array() -> Array:
	var out: Array = []
	out.resize(_size)
	for i: int in _size:
		out[i] = at(i)
	return out


func clear() -> void:
	_items.clear()
	_items.resize(_capacity)
	_head = 0
	_size = 0
