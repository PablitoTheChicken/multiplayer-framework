# MPF — a multiplayer framework for Godot

Sessions, replication, server-validated actions, proximity queries and save
data for **Godot 4.4+**. Built for co-op, PvE, social and survival games.

One API covers single player, listen servers, dedicated servers and Steam P2P —
only the transport changes.

```gdscript
Net.host_offline()                              # single player
Net.host({"transport": "enet", "port": 27015})  # listen server
Net.host_dedicated(27015)                       # headless authoritative server
Net.join("203.0.113.10:27015")                  # or a Steam id, or an MpfLobby
```

## Install

Copy `addons/mpf/` into your project and enable **MPF** in
Project Settings → Plugins. That registers three autoloads — `MPF`, `Net`,
`Save` — and nothing else.

## What you get

**Networking** — transport abstraction (ENet / offline / Steam), authenticated
handshake with version and password checks, peer roster, lobby discovery over
Steam or LAN broadcast, clock sync, heartbeat timeouts, dedicated-server
bootstrap from `--server`.

**Replication** — `MpfNetIdentity` for identity and authority, `MpfNetWorld`
for spawning with automatic late-join sync, `MpfNetState` for replicated
key/value data, `MpfNetTransform` with snapshot interpolation, and per-peer
interest management.

**Gameplay primitives** — `MpfAction` turns "client asks, server validates,
everyone applies" into one component with rate limits, cooldowns, range and
line-of-sight checks built in. `MpfProximity` and `MpfProximitySensor` give you
proximity prompts, triggers and aggro ranges.

**Data** — versioned save profiles with atomic writes, backups, checksums and
migrations, plus server-authoritative per-player persistence with private /
owner / public replication scopes.

**Security by construction** — every message passes through one validated
funnel. Direction, authentication, rate limit, payload size and schema are
enforced in a single place instead of per RPC.

## Try it

The demo in `examples/sandbox/` shows the whole stack: session control,
spawning, replicated movement, a proximity prompt, and a door driven by a
server-validated action.

Two windows without exporting: **Debug → Customize Run Instances → 2**, with
`--host` on the first and `--join` on the second.

## Test

```powershell
pwsh tests/run_tests.ps1
```

Launches a host and a client as separate processes and asserts spawning, state
replication, transform replication and clock sync over a real socket.

## Development setup

`project.godot` enables the [godot-ai](https://github.com/godot-ai) MCP addon,
used here for AI-assisted editing. It is deliberately **not** vendored into this
repository. If you clone this project, either install that addon or delete its
two entries from `project.godot` — the `_mcp_game_helper` autoload and the
`addons/godot_ai/plugin.cfg` line under `[editor_plugins]`. MPF itself does not
depend on it.

## Documentation

- **[AGENTS.md](AGENTS.md)** — architecture, the authority model, conventions,
  recipes and known limits. Start here.
- **[CLAUDE.md](CLAUDE.md)** — workflow notes for AI agents.

## Status

Early. The architecture is sound and the verified paths are genuinely verified,
but several subsystems have never executed — the Steam transport among them —
and world persistence, physics replication and client prediction are not
implemented. **[AGENTS.md §11](AGENTS.md)** lists exactly what is proven, what
is unproven, and what is missing. Read it before depending on a feature.

## License

MIT
