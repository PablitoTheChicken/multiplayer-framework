# CLAUDE.md

**Read [AGENTS.md](AGENTS.md) first.** It is the authoritative guide to this
repository's architecture, conventions and known limits. This file only adds
workflow notes.

## What this repo is

MPF — a multiplayer framework for Godot 4.4+ targeting co-op / PvE / survival
games. The framework lives in `addons/mpf/`; `examples/sandbox/` is a working
demo; `tests/` holds a cross-process integration suite.

## Before you change anything in `addons/mpf/net/`

Run the integration tests. They exercise the handshake, spawning, state
replication, transform replication and clock sync across two real processes —
paths that cannot be reached in a single process.

```powershell
pwsh tests/run_tests.ps1
```

Expect `INTEGRATION TESTS PASSED` and exit code 0.

## Rules that are easy to get wrong

- Framework code uses `MpfRuntime.net()`, never the `Net` global. Game code
  uses the globals. See AGENTS.md §9 for why.
- Autoload scripts (`addons/mpf/runtime/*.gd`) must not declare `class_name`.
- `@tool` scripts must guard `_ready` / `_exit_tree` / `_process` with
  `if Engine.is_editor_hint(): return`.
- Spawn entities on `Net.peer_ready`, never `Net.peer_joined`.
- Keep comments minimal — a one-line `##` class doc, then only genuinely
  non-obvious logic, explaining *why*.

## Editor quirks worth knowing

- Adding an autoload to a running Godot editor does not register it until the
  editor restarts. Until then, scripts referencing `Net` or `MPF` show
  `Identifier not found` errors that are **not** real. The game process is
  unaffected.
- After creating scripts with new `class_name` declarations, run a filesystem
  scan before referencing them from another script.
- Killing `*.console.exe` on Windows leaves the real `.exe` running and holding
  the port. `could not bind port 27015` almost always means a stale process.

## Honest status

Working and verified: ENet transport, handshake, roster, spawning, state and
transform replication, clock sync, save profiles, per-player data, dedicated
servers, exported builds.

Never executed: Steam transport, lobby service, LAN discovery, save
migrations, encryption, Steam Cloud.

Missing: world persistence, physics-aware replication, client prediction, host
migration. See AGENTS.md §11 before claiming the framework supports something.
