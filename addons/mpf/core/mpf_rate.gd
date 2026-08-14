class_name MpfRate
extends RefCounted
## Token-bucket rate limiter keyed by an arbitrary value.

var _buckets: Dictionary = {}


## Consumes one token. Returns false when [param key] is over budget.
## [param rate] is refills per second, [param burst] the bucket size.
func allow(key: Variant, rate: float, burst: float = 0.0) -> bool:
	if rate <= 0.0:
		return true
	var capacity := maxf(1.0, burst if burst > 0.0 else rate)
	var now := float(Time.get_ticks_msec()) * 0.001
	var bucket: Array = _buckets.get(key, [capacity, now])
	var tokens := minf(capacity, float(bucket[0]) + (now - float(bucket[1])) * rate)
	if tokens < 1.0:
		_buckets[key] = [tokens, now]
		return false
	_buckets[key] = [tokens - 1.0, now]
	return true


func available(key: Variant, rate: float, burst: float = 0.0) -> int:
	var capacity := maxf(1.0, burst if burst > 0.0 else rate)
	var now := float(Time.get_ticks_msec()) * 0.001
	var bucket: Array = _buckets.get(key, [capacity, now])
	return int(minf(capacity, float(bucket[0]) + (now - float(bucket[1])) * rate))


func forget(key: Variant) -> void:
	_buckets.erase(key)


func clear() -> void:
	_buckets.clear()
