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
state.changed.connect(func(key, value, old): ...)   # fires on every peer
```

`define()` deliberately does not send, so loading a scene costs no bandwidth.
Full state is resent automatically to every joining peer.

---

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

Set `Save.players.key_provider` to the Steam id in production. The default
falls back to a name-derived key, so two players sharing a name share a save.

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

`tests/run_tests.ps1` asserts spawning, state replication, transform
replication and clock sync across two processes. **Run it after touching
anything in `net/`.**

Gotchas that have already cost time:
- Killing `*.console.exe` leaves the real `.exe` running and holding the port.
  A host reporting `could not bind port 27015` means a stale process survived.
- Adding autoloads to a running editor does not register them until restart;
  scripts referencing `Net` show false parse errors until then.

---

## 11. Known limits — read before promising anything

**Unproven.** The Steam transport has never executed (GodotSteam is not
installed); nor have the lobby service, LAN discovery, save migrations,
encryption, or the Steam Cloud backend. Treat them as unwritten.

**Missing.**
- **World persistence.** `Save` persists player profiles only. Placed
  buildings, chest contents and dropped items are *not* saved. This is the
  largest gap for survival games.
- **Physics replication.** `MpfNetTransform` writes transforms directly, which
  fights a `RigidBody3D` solver. Freeze bodies on non-authoritative peers.
  Godot physics is not deterministic across machines, so physics objects must
  be simulated on the server and replicated, never simulated independently.
- **Client prediction / reconciliation.** Movement is owner-asserted, not
  input-simulated. A modified client can move implausibly; `max_server_speed`
  bounds it but does not eliminate it. Acceptable for PvE, **not** for
  competitive PvP.
- **Host migration.** The host leaving ends the session.
- No delta compression; payloads are Dictionaries via `var_to_bytes`.

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
