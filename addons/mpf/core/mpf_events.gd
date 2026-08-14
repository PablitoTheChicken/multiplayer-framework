class_name MpfEvents
extends RefCounted
## String-keyed event bus. Listeners bound to freed objects are pruned automatically.

signal any(event: StringName, payload: Variant)

var _subs: Dictionary = {}


func on(event: StringName, callback: Callable, once_only: bool = false) -> void:
	if not callback.is_valid():
		MpfLog.warn("events", "Ignored invalid callback", {"event": String(event)})
		return
	var list: Array = _subs.get(event, [])
	for entry: Dictionary in list:
		if (entry["cb"] as Callable) == callback:
			entry["once"] = once_only
			return
	list.append({"cb": callback, "once": once_only})
	_subs[event] = list


func once(event: StringName, callback: Callable) -> void:
	on(event, callback, true)


func off(event: StringName, callback: Callable) -> void:
	if not _subs.has(event):
		return
	var list: Array = _subs[event]
	for i: int in range(list.size() - 1, -1, -1):
		if (list[i]["cb"] as Callable) == callback:
			list.remove_at(i)
	if list.is_empty():
		_subs.erase(event)


## Clears one event, or every event when [param event] is empty.
func clear(event: StringName = &"") -> void:
	if event == &"":
		_subs.clear()
	else:
		_subs.erase(event)


func has_listeners(event: StringName) -> bool:
	return not (_subs.get(event, []) as Array).is_empty()


## Dispatches to every listener. Callbacks may take 0, 1 (payload) or 2
## (payload, event) arguments. Returns how many ran.
func emit(event: StringName, payload: Variant = null) -> int:
	any.emit(event, payload)
	if not _subs.has(event):
		return 0
	var list: Array = (_subs[event] as Array).duplicate()
	var dead: Array[Callable] = []
	var delivered := 0
	for entry: Dictionary in list:
		var cb: Callable = entry["cb"]
		if not cb.is_valid():
			dead.append(cb)
			continue
		match cb.get_argument_count():
			0:
				cb.call()
			1:
				cb.call(payload)
			_:
				cb.call(payload, event)
		delivered += 1
		if entry["once"]:
			dead.append(cb)
	for cb: Callable in dead:
		off(event, cb)
	return delivered
