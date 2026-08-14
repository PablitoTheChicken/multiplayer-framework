class_name MpfCodec
extends RefCounted
## Serialises save payloads with a version header and an integrity checksum.
##
## JSON is the default because a save you can open in a text editor is a save
## you can debug. Binary keeps Godot types like [Vector3] intact and is
## smaller. Neither encodes Objects, so loading a save can never instantiate
## a script.

enum Format { JSON, BINARY }

const MAGIC := "MPFS"


static func encode(data: Dictionary, version: int, format: Format = Format.JSON) -> PackedByteArray:
	var envelope := {
		"magic": MAGIC,
		"v": version,
		"t": int(Time.get_unix_time_from_system()),
		"f": int(format),
		"sum": _checksum(_payload_bytes(data, format)),
		"data": data,
	}
	if format == Format.BINARY:
		return var_to_bytes(envelope)
	return JSON.stringify(envelope, "\t").to_utf8_buffer()


## Returns `{ok, version, data, saved_at, error}`. A checksum mismatch still
## returns the data with `ok` false, so a caller can choose to recover it.
static func decode(bytes: PackedByteArray) -> Dictionary:
	var result := {"ok": false, "version": 0, "data": {}, "saved_at": 0, "error": ""}
	if bytes.is_empty():
		result["error"] = "empty file"
		return result
	var envelope: Variant = _parse(bytes)
	if typeof(envelope) != TYPE_DICTIONARY:
		result["error"] = "unrecognised save format"
		return result
	var dict: Dictionary = envelope
	if String(dict.get("magic", "")) != MAGIC:
		result["error"] = "not an MPF save"
		return result
	var format := int(dict.get("f", Format.JSON)) as Format
	var data: Dictionary = dict.get("data", {}) as Dictionary
	result["version"] = int(dict.get("v", 0))
	result["saved_at"] = int(dict.get("t", 0))
	result["data"] = data
	var expected := String(dict.get("sum", ""))
	if expected != "" and expected != _checksum(_payload_bytes(data, format)):
		result["error"] = "checksum mismatch"
		return result
	result["ok"] = true
	return result


static func _parse(bytes: PackedByteArray) -> Variant:
	var text := bytes.get_string_from_utf8()
	if text.strip_edges().begins_with("{"):
		var parsed: Variant = JSON.parse_string(text)
		if typeof(parsed) == TYPE_DICTIONARY:
			return parsed
	return bytes_to_var(bytes)


static func _payload_bytes(data: Dictionary, format: Format) -> PackedByteArray:
	if format == Format.BINARY:
		return var_to_bytes(data)
	# JSON has one number type, so an int written as 10 comes back as 10.0 and
	# re-serialises differently. Checksumming the value after a normalising
	# roundtrip is what makes encode and decode agree on the same bytes.
	return JSON.stringify(JSON.parse_string(JSON.stringify(data))).to_utf8_buffer()


static func _checksum(bytes: PackedByteArray) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(bytes)
	return context.finish().hex_encode()
