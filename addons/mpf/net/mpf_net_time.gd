class_name MpfNetTime
extends RefCounted
## Estimates a clock shared by every peer, so timestamps mean the same thing
## on both sides of the wire.

signal became_synced()

var offset_ms: float = 0.0
var rtt_ms: float = 0.0
var synced: bool = false

var _samples: MpfRing


func _init(sample_count: int = 12) -> void:
	_samples = MpfRing.new(sample_count)


static func local_ms() -> float:
	return float(Time.get_ticks_msec())


func now() -> float:
	return (local_ms() + offset_ms) * 0.001


func now_ms() -> float:
	return local_ms() + offset_ms


## Seeds a rough offset from a single server timestamp, before any ping has
## completed. This deliberately does not enter the sample ring: it has no
## measured round trip, and a zero-latency sample would win the lowest-rtt
## selection below and dominate the estimate until it aged out.
func bootstrap(server_ms: float) -> void:
	offset_ms = server_ms - local_ms()


## Feeds one completed ping exchange into the estimate.
func submit(sent_ms: float, server_ms: float, received_ms: float) -> void:
	var round_trip := received_ms - sent_ms
	var estimated_offset := server_ms + round_trip * 0.5 - received_ms
	_samples.push({"rtt": round_trip, "offset": estimated_offset})
	_recompute()
	if not synced:
		synced = true
		became_synced.emit()


func _recompute() -> void:
	# Pick the lowest-latency sample rather than averaging: a packet that took
	# an unusually long path carries an unusually wrong offset, and averaging
	# spreads that error around instead of discarding it.
	var best: Dictionary = {}
	var rtt_total := 0.0
	for sample: Dictionary in _samples.to_array():
		rtt_total += float(sample["rtt"])
		if best.is_empty() or float(sample["rtt"]) < float(best["rtt"]):
			best = sample
	if best.is_empty():
		return
	rtt_ms = rtt_total / float(_samples.size())
	# Ease toward the estimate so a correction never teleports interpolated nodes.
	offset_ms = lerpf(offset_ms, float(best["offset"]), 1.0 if not synced else 0.25)


func reset() -> void:
	_samples.clear()
	offset_ms = 0.0
	rtt_ms = 0.0
	synced = false
