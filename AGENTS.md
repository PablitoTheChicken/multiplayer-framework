# MPF — agent guide

Reference for anyone (human or AI) writing code in this repository. Read this
before touching `addons/mpf/`.

MPF is a multiplayer framework for Godot 4.4+ aimed at **co-op, PvE, social and
survival** games. It provides sessions, replication, validated client requests,
spatial queries and save data. It does **not** provide combat, inventory or UI —
those are things you build *with* it.

---

## 1. Quick start

Copy `addons/mpf/` into a project and enable **MPF** in Project Settings →
Plugins. That registers three autoloads and nothing else:

| Autoload | Purpose |
|---|---|
| `MPF` | event bus, fixed tick clock, framework config |
| `Net` | sessions, peers, all message routing |
| `Save` | profiles, migrations, per-player persistence |

```gdscript
Net.host_offline()                              # single player
Net.host({"transport": "enet", "port": 27015})  # listen server
Net.host_dedicated(27015)                       # headless, no local player
Net.join("203.0.113.10:27015")                  # or a Steam id, or an MpfLobby
```

A dedicated build needs no separate code path — launch it with
`--server --port=27015` and `Net` bootstraps itself.

---

## 2. The authority model — read this first

Every decision in this framework comes back to **three questions, not two**:

```gdscript
Net.is_server()        # do I own the simulation?  true when hosting, dedicated, OR offline
Net.is_client()        # am I connected to a remote authority?  false when offline
identity.is_owner()    # is this specific entity mine to drive?
```

`is_server()` is **true when offline on purpose**. Single player is a session
with one peer, so the same scripts run in both without branching.

`is_owner()` is separate because in a 4-player game every client is a
non-server that still fully drives its own avatar.

### Where code belongs

| You are writing | Guard with | Why |
|---|---|---|
| rules, damage, loot, spawning | `if not Net.is_server(): return` | only the authority decides outcomes |
| input, camera, local HUD | `if not identity.is_owner(): return` | one machine, one player |
| sound, particles, animation | *no guard* — react to `changed` / `performed` | effects follow facts |
| asking for something | `action.request({...})` | safe from any peer |

**Effects must never branch on role.** If you write
`if Net.is_server(): play_explosion()`, the explosion belongs in a signal
handler instead — then it plays correctly on host, clients and single player
with no extra code.

Never cache `is_owner()` in `_ready()`. Ownership changes when the server
reassigns an entity or a peer reconnects with a new id. Re-apply it from
`identity.owner_changed`.

---

## 3. Layers

```
gameplay/   MpfAction, MpfProximity, MpfProximitySensor
net/        MpfNetIdentity, MpfNetWorld, MpfNetState, MpfNetTransform
            MpfChannel, MpfPeer, MpfLobby, MpfNetTime, MpfLobbyService
net/transport/  MpfTransport → offline | enet | steam
data/       MpfProfile, MpfCodec, backends, MpfPlayerDataService
core/       MpfLog, MpfEvents, MpfTick, MpfSchema, MpfRate, MpfRing, MpfPool,
            MpfUtil, MpfRuntime
runtime/    the three autoload scripts
```

Built on Godot's own multiplayer stack: `MultiplayerAPI`, `MultiplayerPeer`,
`@rpc`, and `MultiplayerSpawner`. It does **not** use
`MultiplayerSynchronizer` (no validation hook, edit-time config, one packet per
node) or `set_multiplayer_authority()` (replaced by `MpfNetIdentity`).

---

## 4. Networked entities

Add an **`MpfNetIdentity`** as a child of any node to give it a network
identity. Then add components beside it:

```
Crate (RigidBody3D)
├── NetIdentity      authority = SERVER, relevancy_range = 40
├── NetTransform     replicates position/rotation
├── NetState         replicated key/value bag
└── NetAction        a validated request players can make
```

- `authority = SERVER` — only the server may change it.
- `authority = OWNER` — that client drives it, server relays.
- `net_id` left at 0 is derived from the scene path, so every peer agrees.
  Spawned entities get a server-allocated **negative** id, keeping the two
  ranges disjoint.
- `relevancy_range > 0` means peers further away are not sent updates. Set it
  on anything numerous and local; leave 0 for objectives.

### Spawning

Put one **`MpfNetWorld`** in your gameplay scene.

```gdscript
world.register_scene(&"crate", preload("res://crate.tscn"))
var node := world.spawn(&"crate", {"loot_tier": 2}, peer_id)   # server only
```

`props` are applied to matching **exported** properties of the root before
`_ready()`, so use them for anything that must be correct on the first frame.
Late joiners receive everything already spawned.

**Spawn on `Net.peer_ready`, not `peer_joined`** — a joiner may still be loading
the scene, and anything spawned before then never reaches it.

### Replicated values

```gdscript
state.define(&"open", false)              # seed, no network send
state.set_value(&"open", true)            # authority only, replicates
state.get_bool(&"open")                   # also get_float/int/string/vector3
state.changed.connect(func(key, value, old): ...)   # fires on every peer
```

`define()` deliberately does not send, so loading a scene costs no bandwidth.
Full state is resent automatically to every peer that becomes ready.

`strict_keys` (on by default) warns once per key when you read or write
something never passed to `define()`, and when a write changes a value's type.
A mistyped `StringName` is otherwise completely silent.

### Moving platforms and ships

Set `MpfNetTransform.reference_frame` to replicate in another entity's local
space instead of world space. A player standing on a moving ship has a world
position that changes every frame even standing still, so world-space
replication makes riders slide and jitter. The frame travels by net id, so it
resolves whether the ship is spawned or scene-placed. 3D only.

```gdscript
transform.set_reference_frame_node(ship)   # stepped aboard
transform.set_reference_frame_node(null)   # stepped off
```

---

### Physics bodies

Godot physics is **not deterministic across machines**. Two peers simulating
the same body will diverge. So exactly one peer simulates and everyone else
follows the replicated transform.

Add `MpfNetRigidBody` beside the identity and transform:

```
Crate (RigidBody3D)        ← unchanged: your mass, material, layers, damping
├── NetIdentity
├── NetTransform
└── NetRigidBody
```

On the authority it does nothing — the body simulates normally. On every other
peer it sets `freeze = true` in kinematic mode, so the solver stops fighting
the incoming transform. It also **stops sending while the body sleeps**, so a
warehouse of settled crates costs no bandwidth, and resends on wake.

Apply forces through it so they land where the simulation lives:

```gdscript
rigid.push(direction * 12.0)      # server only; wakes the body
rigid.spin(Vector3.UP * 4.0)
rigid.teleport(spawn_point)       # moves and syncs immediately
```

Never replicate the throw *and* the motion — apply the impulse on the server
and let the resulting transform replicate by itself.

## 5. Client requests — `MpfAction`

Attacks, interactions, purchases and ability casts are all one shape: the
client asks, the server validates, everyone applies the confirmed result.

```gdscript
action.validator = func(peer_id: int, payload: Dictionary) -> String:
    if not _has_key(peer_id): return "needs a key"
    return ""                                  # "" allows it

action.request({"slot": 2})                    # any peer
action.performed.connect(func(peer_id, payload): ...)   # every peer, after confirm
action.rejected.connect(func(reason): ...)              # requester only
```

Built-in server-side checks run *before* your validator: rate limit, cooldown,
`max_range`, `require_line_of_sight` and an optional payload schema. A client
that lies about distance or spams the request is rejected before your code runs.

---

## 6. Proximity

`MpfProximity` marks a point of interest; `MpfProximitySensor` on the player
reports which one is in focus. Neither draws UI — that stays yours.

```gdscript
sensor.focus_changed.connect(func(current, previous): _show_prompt(current))
sensor.trigger_focus(&"open_door")     # on input
```

The sensor is **client-side only** and can be lied to. That is fine, because
`MpfAction` re-checks range and line of sight server-side. Predict on the
client for feel; decide on the server for correctness.

---

## 7. Custom messages

Do not write `@rpc` functions. Register a channel:

```gdscript
Net.register_channel(&"chat", _on_chat, {
    "direction": "to_server",
    "rate": 5.0,
    "schema": {"text": {"type": TYPE_STRING, "max_length": 200}},
})
Net.send_to_server(&"chat", {"text": "hi"})
```

Everything funnels through three `@rpc` entry points in `Net`, so direction,
auth, rate limit, size cap and schema are enforced in one place rather than by
discipline. `"any_peer"` means *any* peer — a missing check is a hole.

On a host, `send_to_server` dispatches locally, so a listen server runs exactly
the same path as a remote client. There is no host special case anywhere.

---

## 8. Saving

```gdscript
var profile := Save.open("slot_1")
profile.set_value("stats/kills", profile.get_value("stats/kills", 0) + 1)
profile.save()

Save.register_migration(2, func(d): d["coins"] = d.get("money", 0); return d)
```

Writes are atomic (temp file + rename) with a `.bak` kept, and checksummed.
Neither codec encodes Objects, so loading a save can never instantiate a script.

For multiplayer progression the server is the only writer:

```gdscript
Save.players.register_field(&"level", 1, MpfPlayerData.Scope.PUBLIC)  # or OWNER / PRIVATE
Save.players.get_for(peer_id).add(&"xp", 50)
```

### Identity — who a save belongs to

**The server decides, never the peer.** A client that picks its own storage key
can load anyone else's progression simply by claiming their name, so
`MpfPeer.storage_key` is assigned during the handshake from the strongest
available identity:

1. A **verified platform id** — only believed when the transport established it
   (Steam), or when `trust_client_identity` is explicitly enabled.
2. A **server-issued token**, stored locally by the client and presented on
   reconnect. Unguessable rather than merely unlikely.
3. A **guest key** derived from the name, as a last resort.

Never derive a save key from `display_name` in game code. Override
`Save.players.key_provider` only if you have a stronger identity than the
framework does.

### World persistence

Mark an entity's identity `persistent` and it is included in a world snapshot.
Spawned entities are rebuilt on load; scene-placed ones keep their node and
have their replicated state restored onto it.

```gdscript
Save.save_world(world)          # server only
Save.load_world(world)          # returns entities restored, or -1 if no save
```

Transforms are stored as float arrays so the result stays JSON-safe. State
values must be JSON-safe too unless the save format is binary.

---

## 9. Conventions for this repo

- **Minimal comments.** One short `##` class doc; comment only genuinely
  non-obvious logic, and say *why*, not *what*.
- **Framework code must not reference `Net` / `Save` / `MPF` directly.** Use
  `MpfRuntime.net()` etc. GDScript resolves autoload names at parse time, so a
  direct reference breaks every addon script until the plugin has been enabled
  once. Game code has no such problem and should use the globals.
- **Autoload scripts have no `class_name`** — it would collide with the
  singleton name.
- Static typing everywhere. `snake_case` members, `PascalCase` classes, `Mpf`
  prefix on every global class.
- Components implement `_get_configuration_warnings()` so mistakes surface in
  the editor, not at runtime. `@tool` scripts must guard `_ready`, `_exit_tree`
  and `_process` with `if Engine.is_editor_hint(): return`.

---

## 10. Running, testing, exporting

```powershell
# integration tests — two real processes over a socket
pwsh tests/run_tests.ps1

# two windows from the editor: Debug → Customize Run Instances → 2
#   instance 1 args: --host      instance 2 args: --join

# export (presets already exist)
& $godot --headless --path . --export-debug "Windows Client" ..\build\client\game.exe
& $godot --headless --path . --export-debug "Windows Dedicated Server" ..\build\server\server.exe
```

`tests/run_tests.ps1` runs 108 single-process assertions plus six
cross-process scenarios: `core`, `late_join`, `rejection`, `lossy`,
`persistence` and `three_peer`. **Run it after touching anything in `net/`.**
Use `-Only <scenario>` to run one.

Loopback is a perfect link and hides ordering and interpolation bugs. To make
it behave like a real connection:

```gdscript
Net.simulate_latency_ms = 90.0
Net.simulate_jitter_ms = 40.0
Net.simulate_loss = 0.25     # unreliable channels only
```

Gotchas that have already cost time:
- Killing `*.console.exe` leaves the real `.exe` running and holding the port.
  A host reporting `could not bind port 27015` means a stale process survived.
- Adding autoloads to a running editor does not register them until restart;
  scripts referencing `Net` show false parse errors until then.

---

## 11. Known limits — read before promising anything

**Partly proven.** The Steam layer — lobby lifecycle, discovery, invites, rich
presence, cloud storage — is now exercised against a mock singleton in
`tests/mock_steam.gd`, which proves MPF *calls* Steam correctly. It does not
prove Steam *answers* as expected, and `SteamMultiplayerPeer` cannot be mocked
at all, so the transport itself remains unexecuted. It stays gated behind
`mpf/network/experimental_steam`, off by default.

**Unproven.** LAN discovery, save migrations and save encryption have never
run.

**Missing.**
- **Client prediction / reconciliation.** Movement is owner-asserted, not
  input-simulated. A modified client can move implausibly; `max_server_speed`
  bounds it but does not eliminate it. Acceptable for PvE, **not** for
  competitive PvP.
- **Host migration.** The host leaving ends the session.
- **Relative-space replication is 3D only** and untested with a genuinely
  moving frame. The mechanism exists; a real ship has not been built on it.
- No delta compression; payloads are Dictionaries via `var_to_bytes`.

**Two mistakes the API still allows.** `world.spawn(key, props, owner_peer_id)`
records an owner, but ownership grants nothing unless the entity is
owner-authoritative — pass `MpfNetIdentity.Authority.OWNER` as the fourth
argument, or the server will refuse that peer's writes. And replication catch-up
happens on `peer_ready`, never `peer_joined`; anything sent on `peer_joined`
arrives before the entity exists and is discarded.

---

## 12. General Godot guidance

- Compose with small single-purpose child nodes rather than deep inheritance.
  Every MPF feature is a component for this reason.
- Prefer signals over polling; prefer `_physics_process` for anything touching
  physics and `_process` for visuals.
- Export configuration, don't hard-code it — designers and tests both benefit.
- Use `@onready` for node references, and typed vars everywhere so the compiler
  catches mistakes.
- Keep `res://` paths out of gameplay logic; `preload` at the top of the file.
- `user://` for anything written at runtime. Never write to `res://` — it is
  read-only in an exported game.
- Scene-unique names (`%Node`) beat long `$A/B/C` paths that break when you
  reorganise.
- Run the game headless in CI: `--headless` works for anything without
  rendering, which is how the tests here run.
