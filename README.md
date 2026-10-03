# Resilience tooling (layer 2)

Workspace tools that keep the mod family safe in the one LuaJIT 2.1.0-alpha state
(`bin/lua51.dll`, non-GC64) that the game shares with every mod. They use only the
Python standard library and the workspace LuaJIT. Nothing here ships in a mod.

| File | Purpose |
| --- | --- |
| `lint.py` | Static lint of mod sources, with a baseline that only ratchets down |
| `lint-repos.json` | Repos to scan: the latest published checkouts (read only), their globs and allowed globals |
| `lint-baseline.json` | Known violations: count per (repo, kind, file, rule, line text) |
| `hostile_vm.lua` | Canonical test helper; copy it byte-identical to a mod's `tests/hostile_vm.lua` |
| `tests/` | `unittest` for `lint.py`; a Lua test for `hostile_vm.lua` that runs in both VMs |

## Lint rules

| Rule | Catches | Why |
| --- | --- | --- |
| R1 `global-cdef-function` | A function prototype in `ffi.cdef` without a private `__asm__` label. Also flagged: a label that repeats the name, and a cdef argument that is not a literal. Typedefs are fine. | `ffi.cdef` keeps the first prototype for a name in the whole process and silently ignores later ones. Use `void *x_GetModuleHandleA(const char *) __asm__("GetModuleHandleA");`. |
| R2 `type-string` | `ffi.cast/typeof/new/metatype` (and `sizeof/alignof/istype/offsetof`) given a string, or a local string constant, that holds a function-pointer type `(*)` or an anonymous `struct {` / `union {` / `enum {` | Each evaluation creates new C types: 3 for a function-pointer string, 2 for an anonymous struct. The 65,536-entry table never frees them. Declare a named typedef once and reuse the ctype. |
| R3 `raw-store` | A store through `ffi.cast(...)[i] = v` or `.field = v`, or through a local cast from a constant address (`local WORDS = ffi.cast('uint32_t *', 0)`) | An access violation on a stale pointer kills the game, and `pcall` cannot catch it. Stores through other pointer variables are not detected. |
| R4 `gc-mutation` | `collectgarbage` with any option except `'count'`: no argument, a variable option, or `pcall(collectgarbage, 'stop')` | It changes the GC for the game and every mod, and running out of memory in compiled code kills the game. |
| R5 `jit-global` | `jit.flush`, any use of `jit.opt` (including `require('jit.opt')` and `<x>.opt.start`), `jit.attach`, and `jit.off()`/`jit.on()` with no argument. Local aliases of `jit` count too. | Each one affects every mod's compiled code. `jit.off(fn)` with an argument is fine. |
| R6 `os-clock` | `os.clock` | It aborts trace compilation (this LuaJIT has no trace stitching) and is coarse. Time with QueryPerformanceCounter through the FFI. |
| R7 `loader-version` | A numeric comparison with the loader's `version`: tables named `*loader*`, aliases of `CowboyBingusModLoader`, or `rawget(_G, '...Loader').version`. `type(loader.version)` is fine. | The loader's internal version differs from its release number (v18 reports 17). Check capabilities instead: `loader.api`, `loader.jit`, functions. |
| R8 `global-write` (sources only) | `GSET` instructions in the compiled bytecode, plus `rawset(_G, 'x', ...)`, `_G.x =` and `_G['x'] =`. `update`, `shutdown`, `render` and the repo's `allowed_globals` are exempt. | Any other global leaks into the shared state, like CV's accidental `_`. |
| R9 `catch-previous` (sources only) | `pcall`/`xpcall` of `previous...`/`original...`, and `error((...), 0)` | Catching another layer's error and rethrowing it from the mod's frame makes vanilla errors look like mod errors. |

Suppression: put `-- lint-ok: R<n> <reason>` on the reported line. The reason is required. To
name several rules, write `R2,R3`. Inside a cdef string, use a C comment: `/* -- lint-ok: R1 reason */`.

How R8 works: `luajit -bl` prints no line numbers. `lint.py` therefore compiles every source
file (it never runs them) in one workspace LuaJIT process, with `LUA_PATH` set to the LuaJIT
`src` folder. It lists each `GSET` with the same `jit.bc` module that `-bl` uses, and takes its
line from `jit.util.funcinfo`. If a file does not compile, the lint stops with exit code 2.

## Running

```
python lint.py                           # repo x rule table
python lint.py scan --list               # every violation, with its detail
python lint.py scan --json               # machine-readable output
python lint.py check                     # exit 1 when any count rose above lint-baseline.json
python lint.py update                    # rewrite the baseline after fixes; refuses increases
python lint.py update --allow-increase   # accept increases: the first baseline, or reviewed changes
```

Options:
- `--tests` also lints `tests/` (rules R1-R7).
- `--repo NAME=PATH` lints another checkout against the baseline, e.g.
  `--repo ShallowWaterDiving=publication\resilience-v1\checkouts\ShallowWaterDiving`.
- `--only NAME` limits the scan, the check and the update to these repos.
- `--config`, `--baseline` and `--luajit` choose other files.

The baseline identity is (repo, kind, file, rule, line text with whitespace collapsed). Editing a
violating line gives it a new identity: `check` reports it as NEW and the old line as "fixed - run
update". Fix it or mark it `lint-ok`. Otherwise, after review, accept it with
`update --allow-increase`. `update` keeps entries outside the current scope: other repos when
`--only` is set, and test entries when `--tests` is not.

Exit codes: 0 means OK; 1 means new violations (`check`) or a refused update; 2 means a
configuration or compile error.

## hostile_vm.lua

Pure Lua plus FFI, in Lua 5.1 syntax. It runs in the workspace LuaJIT and in the game's
`lua51.dll`. Each function is documented at the top of the file: what game behaviour it imitates,
and why.

| Function | Imitates |
| --- | --- |
| `H.clash(names)` | A mod that loaded first and declared these names with a wrong 6-pointer prototype. Call it before anything declares them. Returns `status[name]`: `'clashed'`, `'already declared'` or `'error: ...'`. |
| `H.next_ctype()`, `H.ctype_growth(fn, ...)` | The shared 65,536-entry C type table. Returns the number of types `fn` created, excluding the probe's own 2 ids, followed by `fn`'s results. Measure a repeated call, because the first use interns array and pointer types. |
| `H.chain(env, kind [, options])`, `H.chain_restore(env)` | An abusive neighbour in the `update` chain. Kinds: `'throw_below'` (raises a table error object; `options.raise_on` takes a frame number or a function), `'drop_args'`, `'double_call'`, `'skip_odd_frames'`, `'rehook'`. Call it before the mod installs to put the neighbour below the mod, after to put it above. |
| `H.gc_hostile([pause])` | A neighbour setting the GC pause to 400. Returns a restore function. |
| `H.jit_churn()` | A full code cache or a flushing neighbour. Returns `flush()`, which calls `jit.flush()` (tests only). |
| `H.aligned16(address [, label])` | The game's `movaps` code, which faults on buffers that are not 16-byte aligned. Use it in native fakes. |
| `H.heap_peak(fn, ...)` | Returns the heap growth in KB with the GC stopped, then `fn`'s results. Use it with `H.gc_hostile` to bound a mod's allocation bursts. |

```lua
local H = dofile(tests .. '/hostile_vm.lua')
local status = H.clash({'GetModuleHandleA', 'ReadProcessMemory', 'VirtualQuery'})  -- before the mod loads
local env = {update = fake_game_update}
H.chain(env, 'throw_below', {raise_on = 3})   -- below the mod
install_mod(env)
env.update(1 / 60)                             -- warm-up frame
assert(H.ctype_growth(env.update, 1 / 60) == 0, 'C types created per frame')
```

## Tests

```
python -m unittest discover -s tests -v
```

- `test_lint.py` covers every rule, the `lint-ok` comment and the baseline ratchet. In
  `tests/fixtures/sample_mod`, each expected violation is marked `expect: R<n>`, and a scan must
  report exactly the marked lines.
- `test_hostile_vm.py` runs `tests/test_hostile_vm.lua` twice: in the workspace LuaJIT, and in the
  installed game's `lua51.dll` through `PerformanceBaseline/game_lua.py`. The game is never
  started.
