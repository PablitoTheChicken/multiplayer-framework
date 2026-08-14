class_name MpfSchema
extends RefCounted
## Payload validation for network channels.
##
## A field spec is a [enum @GlobalScope.Variant.Type] constant, an [Array]
## holding one spec ("array of that"), a nested schema [Dictionary], or a
## constraint dict [code]{"type": .., "min": .., "max": .., "max_length": ..,
## "values": [..], "optional": true}[/code]. A key prefixed with [code]?[/code]
## is optional.

const CONSTRAINT_KEYS: PackedStringArray = ["type", "min", "max", "max_length", "values", "optional"]
## Recursion guard. Legitimate payloads are shallow; a deeply nested one is
## either a bug or an attempt to exhaust the stack during validation.
const MAX_DEPTH := 8


## Returns an empty string when valid, otherwise the reason.
static func validate(payload: Variant, schema: Dictionary, depth: int = 0) -> String:
	if schema.is_empty():
		return ""
	if depth > MAX_DEPTH:
		return "nested more than %d levels deep" % MAX_DEPTH
	if typeof(payload) != TYPE_DICTIONARY:
		return "expected Dictionary, got %s" % type_string(typeof(payload))
	var dict: Dictionary = payload
	for raw_key: Variant in schema:
		var key := String(raw_key)
		var optional := key.begins_with("?")
		var field := key.substr(1) if optional else key
		var spec: Variant = schema[raw_key]
		if _is_optional_spec(spec):
			optional = true
		if not dict.has(field):
			if optional:
				continue
			return "missing required field '%s'" % field
		var reason := _check(dict[field], spec, depth + 1)
		if reason != "":
			return "field '%s': %s" % [field, reason]
	return ""


## Copy of [param payload] containing only keys named in [param schema].
static func strip(payload: Dictionary, schema: Dictionary) -> Dictionary:
	var out := {}
	for raw_key: Variant in schema:
		var key := String(raw_key)
		var field := key.substr(1) if key.begins_with("?") else key
		if payload.has(field):
			out[field] = payload[field]
	return out


static func _is_optional_spec(spec: Variant) -> bool:
	return typeof(spec) == TYPE_DICTIONARY and bool((spec as Dictionary).get("optional", false))


static func _check(value: Variant, spec: Variant, depth: int = 0) -> String:
	if depth > MAX_DEPTH:
		return "nested more than %d levels deep" % MAX_DEPTH
	match typeof(spec):
		TYPE_INT:
			return _check_type(value, int(spec))
		TYPE_ARRAY:
			var arr_spec: Array = spec
			if typeof(value) != TYPE_ARRAY:
				return "expected Array, got %s" % type_string(typeof(value))
			if arr_spec.is_empty():
				return ""
			var items: Array = value
			for i: int in items.size():
				var reason := _check(items[i], arr_spec[0], depth + 1)
				if reason != "":
					return "index %d: %s" % [i, reason]
			return ""
		TYPE_DICTIONARY:
			var dict_spec: Dictionary = spec
			if _looks_like_constraint(dict_spec):
				return _check_constraint(value, dict_spec)
			return validate(value, dict_spec, depth + 1)
	return ""


static func _looks_like_constraint(spec: Dictionary) -> bool:
	if not spec.has("type"):
		return false
	for key: Variant in spec:
		if not CONSTRAINT_KEYS.has(String(key)):
			return false
	return true


static func _check_constraint(value: Variant, spec: Dictionary) -> String:
	var reason := _check_type(value, int(spec.get("type", TYPE_NIL)))
	if reason != "":
		return reason
	if spec.has("values") and not (spec["values"] as Array).has(value):
		return "value not allowed"
	var kind := typeof(value)
	if kind == TYPE_INT or kind == TYPE_FLOAT:
		var number := float(value)
		if spec.has("min") and number < float(spec["min"]):
			return "below minimum %s" % spec["min"]
		if spec.has("max") and number > float(spec["max"]):
			return "above maximum %s" % spec["max"]
	if spec.has("max_length"):
		var limit := int(spec["max_length"])
		match kind:
			TYPE_STRING, TYPE_STRING_NAME:
				if String(value).length() > limit:
					return "longer than %d characters" % limit
			TYPE_ARRAY:
				if (value as Array).size() > limit:
					return "more than %d entries" % limit
			TYPE_DICTIONARY:
				if (value as Dictionary).size() > limit:
					return "more than %d keys" % limit
	return ""


static func _check_type(value: Variant, expected: int) -> String:
	if expected == TYPE_NIL:
		return ""
	var actual := typeof(value)
	if actual == expected:
		return ""
	# JSON and the wire format blur int/float and String/StringName, so accept
	# the lossless widenings.
	if expected == TYPE_FLOAT and actual == TYPE_INT:
		return ""
	if expected == TYPE_STRING_NAME and actual == TYPE_STRING:
		return ""
	if expected == TYPE_STRING and actual == TYPE_STRING_NAME:
		return ""
	return "expected %s, got %s" % [type_string(expected), type_string(actual)]
