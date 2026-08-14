# The door is a plain StaticBody3D. Nothing about being networked changes what
# kind of node it is - the framework attaches to it as child components.
extends StaticBody3D
## A door showing the full request path: a client asks, the server checks range
## and line of sight, then flips replicated state that every peer reacts to.
##
## Every line below is commented because this file is the worked example for
## how server-authoritative gameplay is written with MPF.

# Replicated key/value store for this entity. Only the authority (the server)
# may write to it; every peer can read it and is told when it changes.
@onready var state: MpfNetState = $NetState

# The request gate. Clients call request() on it; the server decides.
# Its max_range and require_line_of_sight are configured in sandbox.tscn.
@onready var action: MpfAction = $NetAction

# The point of interest a player's MpfProximitySensor can find. It carries no
# UI of its own - it only reports focus, and the game decides what to draw.
@onready var point: MpfProximity = $Prompt

# The floating "[E] Toggle door" sign. This is the game's prompt UI, not the
# framework's, which is why it is an ordinary Label3D you can restyle freely.
@onready var sign_label: Label3D = $PromptLabel

# Purely visual. Moving this does not move the collision shape, which is fine
# for a demo - the point is that it moves at the same moment on every machine.
@onready var mesh: MeshInstance3D = $Mesh

# Remembered so the open position can be expressed relative to wherever the
# artist placed the mesh, instead of hard-coding a world height.
var _closed_y: float = 0.0


func _ready() -> void:
	# Capture the authored resting position before anything animates it.
	_closed_y = mesh.position.y

	# The sign starts hidden and only appears while a player is in range and
	# looking at the door.
	sign_label.visible = false

	# Declare the key and its starting value. define() seeds the value without
	# marking it dirty, so simply loading the scene does not cause a network
	# send - unlike set_value(), which would.
	state.define(&"open", false)

	# Runs on EVERY peer whenever a replicated value lands or is written
	# locally. This is where visuals belong, so they play identically for the
	# host, for remote clients, and in single player.
	state.changed.connect(_on_state_changed)

	# Emitted by whichever player's sensor picks this door as its best target.
	# Purely local to that player - focus is a UI concern, never networked.
	point.focused.connect(_on_focused)
	point.unfocused.connect(_on_unfocused)

	# Runs on EVERY peer once the server has confirmed the action.
	action.performed.connect(_on_performed)

	# Runs ONLY on the peer whose request was refused. Nobody else needs to
	# know that someone else failed to open a door.
	action.rejected.connect(_on_rejected)

	# Installed on every peer, but only ever *called* on the server, because
	# validation happens where the authority is. Assigning it on clients is
	# harmless and keeps this _ready() free of role branches.
	action.validator = _can_use

	# Make the sign read correctly before anyone has touched the door.
	_refresh_sign()


## Server-side rules the client cannot be trusted to enforce. Returning an empty
## string allows the action; any other string is the refusal reason sent back.
##
## Range and line of sight are already checked by MpfAction before this runs, so
## this is for game rules only - "do they hold the key", "is the round live",
## "is this door locked from the other side". This demo has no extra rules.
func _can_use(_peer_id: int, _payload: Dictionary) -> String:
	return ""


## A local player came into range and is looking at the door.
func _on_focused(_finder: Node) -> void:
	sign_label.visible = true


func _on_unfocused(_finder: Node) -> void:
	sign_label.visible = false


## Fires on every peer after the server confirms. The parameter is the peer that
## asked, not the peer running this code.
func _on_performed(peer_id: int, _payload: Dictionary) -> void:
	# The authoritative write is guarded, because only the server may change
	# replicated state. Clients reach this line too, but skip it and instead
	# receive the resulting value a moment later through state.changed.
	if Net.is_server():
		# Read the current value and flip it. bool() guards against the value
		# arriving as something falsy-but-not-a-bool over the wire.
		state.set_value(&"open", not bool(state.get_value(&"open", false)))

	# Deliberately NOT guarded by is_server(). Anything a player should see or
	# hear runs on all peers - this is where a click sound or dust puff would
	# go, so it plays on the host and on clients without extra code.
	MpfLog.info("demo", "Door used", {"by": peer_id})


## Fires only on the requesting peer, with the reason the server gave:
## "out of range", "no line of sight", "on cooldown", "too many requests", or
## whatever string _can_use() returned.
func _on_rejected(reason: String) -> void:
	# Pushed through the global event bus so the door does not need a reference
	# to the HUD. sandbox.gd listens for this and writes it into a Label.
	MPF.events.emit(&"prompt", {"text": "Cannot use door: %s" % reason})


## Fires on every peer, for every key in this entity's state - hence the filter.
func _on_state_changed(key: StringName, value: Variant, _previous: Variant) -> void:
	# One handler serves the whole entity, so ignore keys this visual does not
	# care about. A real door might also watch &"locked" here.
	if key != &"open":
		return

	# Open is 2.4 metres above wherever the mesh started; closed is back home.
	var target := _closed_y + (2.4 if bool(value) else 0.0)

	# Tween rather than snap. The state change is instantaneous and identical
	# everywhere; the animation is local polish on top of that shared fact.
	create_tween().tween_property(mesh, "position:y", target, 0.35)

	_refresh_sign()


## Keeps the sign's wording in step with the replicated state, so a player who
## walks up to an already-open door is offered "Close" rather than "Open".
func _refresh_sign() -> void:
	var verb := "Close" if bool(state.get_value(&"open", false)) else "Open"
	sign_label.text = "[E]  %s door" % verb
	# The framework only knows the word "prompt" because we put it there; this
	# keeps the MpfProximity payload and the sign showing the same thing.
	point.data["prompt"] = "%s door" % verb
