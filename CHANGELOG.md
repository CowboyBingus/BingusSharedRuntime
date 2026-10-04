# Changelog

## Version 1 (first public release)

- `bingus_runtime.lua` provides the shared session table and the update guard (P1-P3, pause and resume), and uses no FFI.
- `bingus_memory.lua` provides memory reads, page checks, module hashes read once per session and a clock that allocates nothing.
- `bingus_write.lua` writes only into committed private read-write memory, checked right before each write.
- Each file declares its Windows functions once per game under private names that carry the file and its version, so copies of different versions run side by side.
- A read-only mod can vendor `bingus_runtime.lua` and `bingus_memory.lua` alone: neither names a Windows function that changes memory.
- `hostile_vm.lua` and `game_lua.py` test mods against a hostile shared Lua state and inside the game's own `lua51.dll`.
- `lint.py` checks mod sources against rules R1-R15, with a baseline that only ratchets down and paths relative to the workspace.
