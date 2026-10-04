# Bingus Shared Runtime

Shared Lua code, test helpers and a lint for Helldivers 2 mods that run inside the game's
LuaJIT state. The runtime is three small Lua files that a mod copies into its own source. The
helpers and the lint are for the mod's tests and builds; they never ship in a mod.

| File | Purpose |
| --- | --- |
| `runtime/bingus_runtime.lua` | The core: the session table every copy shares, and the update guard. No FFI. |
| `runtime/bingus_memory.lua` | The read side: memory reads, page checks, module hashes and a clock. Never changes memory. |
| `runtime/bingus_write.lua` | The write side: checked writes into private read-write memory. |
| `hostile_vm.lua` | Test helper: the game's shared Lua state, made hostile. |
| `game_lua.py` | Runs a Lua file inside the game's own `lua51.dll`, in a test process. |
| `lint.py`, `metrics.py` | Static lint for mod sources (rules R1-R15), with a baseline that only ratchets down. |
| `lint-repos.json`, `lint-baseline.json` | The lint's repo list and baseline for the CowboyBingus mods. |
| `tests/` | Tests for all of the above. |

The repository uses only the Python standard library and a LuaJIT 2.1 executable.

## Why

The game runs its own Lua and every Lua mod in one LuaJIT 2.1.0-alpha state (`bin/lua51.dll`,
non-GC64). Everything in that state is shared:

- **One set of C declarations.** `ffi.cdef` keeps the first declaration of a function or type name
  for the whole game. A later declaration of the same name with another prototype raises no error
  and is ignored. A mod that declares `ReadProcessMemory` under its plain name therefore calls it
  with whatever prototype another mod declared first. The runtime declares every Windows function
  under a private, versioned name with an `__asm__` label naming the real export, for example
  `bingus_memory1_ReadProcessMemory`, and uses only private type names.
- **One update chain.** The game calls the global `update(dt)` every frame and `shutdown()` at the
  end. Each mod wraps the function it finds and calls it from its own. An error anywhere in that
  chain reaches the game, and a mod that catches it hides a vanilla error behind its own name.
- **One C type table, one GC, one JIT code cache.** The type table holds 65,536 entries for the
  game and every mod and never frees one. Running out of Lua memory in compiled code kills the
  game. Per-frame garbage and compiled code add up across mods.

Every mod used to write its own Windows declarations, memory readers, protection checks and update
wrappers. The runtime does it once, tested in the game's own `lua51.dll`.

The update guard follows three rules:

- **P1:** the previous update runs outside `pcall`, so its errors reach the game unchanged, with
  their own value and traceback.
- **P2:** the first failure survives shutdown: the mod's status ends as
  `stopped after: <reason>`.
- **P3:** 8 errors stop the mod. They are counted per burst, so rare transient errors never add up
  to a stop.

## The runtime

### Loading

Each file is one Lua chunk that returns a table and installs nothing until the mod asks:

```lua
local runtime = dofile('bingus_runtime.lua')            -- shared(), guard()
local memory = dofile('bingus_memory.lua').new(runtime) -- reads, page checks, module hashes, time()
dofile('bingus_write.lua').extend(memory)               -- adds write() and write_batch() to memory
```

A mod vendors only the files it needs:

| The mod | Files |
| --- | --- |
| guards its update and reads no memory | `bingus_runtime.lua` |
| reads game memory | `bingus_runtime.lua`, `bingus_memory.lua` |
| writes game memory | all three |

`bingus_runtime.lua` and `bingus_memory.lua` contain none of the names that builds of read-only
mods refuse in their sources: Windows functions that change memory or page protection, load code
or start threads, and the game's `Network.` and `RPC.` namespaces (a test checks the exact
strings). Such a mod can vendor both.

### Vendoring and versions

- Copy the files byte-identical into the mod, for example into `src/`, and never edit them. Take all
  of a mod's files from the same commit. The tests of a mod can compare each copy's SHA-256 with
  the canonical file.
- A build that joins its sources into one chunk can embed each file as
  `local runtime = (function() <file> end)()`. The files declare no global except `BingusRuntime`.
- Each file has a `VERSION` field (1 for all three files today), and its FFI names carry the file
  and the version: `bingus_memory1_*`, `bingus_write1_*`. Each file checks a private sentinel type
  (`bingus_memory1_region`, `bingus_write1_declared`) and declares its names at most once per
  version in the whole game, so a second copy adds no C types.
- Within a version the C declarations never change. A change to them makes a new version with new
  names, so copies of different versions run side by side in one game (tested).
- Every copy of every version shares one global table, `BingusRuntime`: `hashes` (module
  hashes), `statuses` (one per guard), `versions` (the core versions loaded) and `hash_reads`
  (module files read this session). `runtime.shared()` creates it, and repairs it if another mod
  left it incomplete, even `BingusRuntime = {}`. Later versions only add to this layout.

### bingus_runtime.lua: the shared table and the guard

`runtime.shared([globals])` returns the shared table (`globals` defaults to `_G`).

`runtime.guard(options)` builds a guard; `guard.install()` wraps `env.update` and `env.shutdown`
and returns the guard. Options:

| Option | Meaning |
| --- | --- |
| `name` | Required. The key in `BingusRuntime.statuses`; one installed guard per name. |
| `step(dt, ...)` | Runs every frame before the previous update, while the guard runs. |
| `after()` | Runs after the previous update returned, while the guard runs. |
| `stop(reason)` | Runs once, when the guard stops or the game shuts down (`reason` is `'shutdown'` then). Its errors are kept in `status.stop_error`, never raised. |
| `pause(reason)` | Optional. An update below this mod raised: restore the game state and reset the mod to a fresh start. |
| `log(line)` | Receives the guard's few lines: the first error of a burst, pauses, resumes, the stop. Errors in it are ignored. |
| `errors` | Errors that stop the guard (default 8). |
| `resume` | Clean frames below before a paused guard resumes (default 60). |
| `clean` | Error-free frames after which an error count starts again (default 3600, about a minute at 60 FPS). |
| `env` | The table that holds `update` and `shutdown` (default `_G`). |

`guard.stop(reason)` stops the guard from the mod, for example after a refused game build; the
reason counts as the first failure. `guard.running()` is true from `install` until a stop or
shutdown.

With `runtime` and `memory` loaded as above:

```lua
local ok, why = memory.verify_build({exe_sha256 = EXE_SHA256, game_sha256 = GAME_SHA256})
local guard = runtime.guard({name = 'ExampleMod', step = step, stop = restore, pause = restore,
                             log = function(line) log_line(line) end}).install()
if not ok then guard.stop(why) end
```

#### The guard's policy

- Every argument and return value passes through, `nil` values included.
- The mod's `step` and `after` run under `pcall`. An error there counts toward the mod's own
  count. The first error of a burst gets one log line; the mod keeps running.
- The previous update runs outside `pcall` (P1). When it raises, the error leaves the frame
  unchanged; the guard notices on the next frame.
  - With `pause`, the guard calls `pause(reason)` once, skips `step` and `after`, and resumes when
    the updates below have returned on `resume` frames in a row. A `pause` that raises stops the
    guard.
  - Without `pause`, that error stops the guard for the session.
- Errors below are counted apart from the mod's own errors. Either count reaching `errors` stops the
  guard. Each count starts again after `clean` frames without such an error (P3).
- A stopped guard keeps forwarding every frame and never runs `step` or `after` again.
- At shutdown `stop('shutdown')` runs if the guard was still running, and the first failure
  survives as `stopped after: <reason>` (P2). An update below that raised in the last frame counts.

#### Statuses

`guard.status` is `BingusRuntime.statuses[name]`:

| Field | Meaning |
| --- | --- |
| `name`, `version` | The guard's name and the core version that made it. |
| `state` | `new`, `running`, `paused: the previous update failed`, `stopped: <reason>`; after shutdown `stopped` or `stopped after: <first failure>`. |
| `installed` | Whether `install` ran. |
| `errors`, `lower_errors` | The mod's own errors and the errors below it, in the current burst. |
| `pauses` | Pauses this session. |
| `first_error`, `burst_error` | The first own error of the session, and of the current burst. |
| `first_failure` | The first reason the guard stopped, or the failure seen at shutdown. |
| `stop_error` | What `stop` raised, if anything. |

Stop reasons are `the previous update failed`, `stopped after 8 errors: <first error of the
burst>`, `stopped after 8 failed updates below this mod`, `pause failed: <error>` and the mod's own
`guard.stop(reason)`.

### bingus_memory.lua: reads

`require('ffi')` must work (any LuaJIT with the FFI, Windows x64). `memory.new(runtime)` returns an
api; each api keeps its own buffers and counters.

| Call | Returns |
| --- | --- |
| `read(address, size)` | The bytes as a string, or `nil` when they cannot all be read. |
| `read_into(address, size, buffer)` | `true` when all bytes were copied into the caller's buffer. |
| `pointer(bytes [, offset])` | The user-mode pointer stored little-endian at `bytes[offset+1 .. offset+8]`, as `uint8_t *`, or `nil` below 64 KB or outside user space. |
| `address(pointer)` | A pointer, number or integer cdata as a Lua number (exact below 2^53). |
| `distance(a, b)` | `address(a) - address(b)`. |
| `writable_data(address, size)` | `true` when the whole range is committed, private, read-write memory: never code, read-only, guard or module image pages. |
| `queries` | Page queries made so far by this api. |
| `time()` | Seconds from the performance counter, as a Lua number. |
| `module([name])` | A loaded module's base as `uint8_t *`, or `nil`; no name: the executable. |
| `module_hash(module)` | The SHA-256 (uppercase hex) of the module's file, read once per session for every mod. |
| `verify_build({exe_sha256, game_sha256})` | `true`, or `false` and `'game modules unavailable'` or `'unsupported game build'`. |
| `windows` | `{ffi, kernel32, bcrypt}`: the bound functions under their Windows names, for calls the api does not cover. |

`read` and `read_into` take a pointer (`nil` reads nothing); `address`, `distance` and
`writable_data` also take numbers.

### bingus_write.lua: checked writes

`write.extend(api)` adds to an api from `bingus_memory.lua`:

| Call | Does |
| --- | --- |
| `write(address, bytes [, size])` | Writes a string, or `size` bytes of a buffer, to a pointer. `true` when every byte landed. |
| `write_batch(base, size, changes)` | Several writes inside `[base, base + size)` under one check: `changes = {{offset, bytes}, ...}`. Returns `true` and the count, or `false` and how many writes landed, so the caller can undo them. |

Each write checks its whole range with `api.writable_data` right before writing, and refuses
anything but committed private read-write memory. Nothing in the runtime changes page protection
or allocates memory pages. `api.windows.kernel32.WriteProcessMemory` is bound as well.

### Per-frame cost

In-game costs come from measurements in real play. Calls without one are marked unmeasured in game.

| Call | Windows calls | In-game cost | Lua allocation |
| --- | --- | --- | --- |
| guard, per frame | none | unmeasured in game | none |
| `read` | 1 `ReadProcessMemory` | about 1-2 us | the returned string |
| `read_into` | 1 `ReadProcessMemory` | about 1-2 us | none |
| `writable_data` | 1 `VirtualQuery` per memory region in the range | about 0.29 ms per region | none |
| `write` | `writable_data`, then 1 `WriteProcessMemory` | about 0.29 ms per region, plus the write (unmeasured in game) | none |
| `write_batch` | `writable_data` once, then 1 `WriteProcessMemory` per change | as `write` | one pointer per call and per change in interpreted code |
| `time` | 1 `QueryPerformanceCounter` | unmeasured in game | none |
| `address`, `distance` | none | no system call | none |
| `module_hash` | 1 `GetModuleFileNameW`; the first call per module and session also reads and hashes the module file | once per session | a 64 KB path buffer per call, and 1 MB while a file is read |

"None" means 0 bytes, interpreted and compiled, pinned by the tests. A page check costs about 2% of
a 60 FPS frame, so check pages only on frames that write, right before the write.

Compiled code, measured offline in the game's `lua51.dll` with `tests/bench_loop.lua`: a guarded
loop with the clock, three `read_into` and one `read` per frame compiles to 4 traces and
2,500-2,750 bytes of machine code, about 300 of them in traces that start in the runtime's files.
Adding a page check per frame brings it to 8 traces and 4,550-4,700 bytes. Garbage per frame:
0 bytes, compiled and interpreted.

## Test helpers

### hostile_vm.lua

Pure Lua plus FFI, in Lua 5.1 syntax. It runs in a LuaJIT 2.1 executable and in the game's
`lua51.dll`. Copy it byte-identical to a mod's `tests/hostile_vm.lua`. Each function is documented at
the top of the file: what game behaviour it imitates, and why.

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

### game_lua.py

`python game_lua.py <file.lua> [args...]` loads the game's `lua51.dll` into a Python process and runs
the file in a fresh Lua state with the standard libraries. The game is never started. Arguments that
name an existing file or folder are made absolute, what the file prints is printed at the end, and an
error prints `ERROR: <message>` and exits with 1. The DLL comes from `HD2_LUA51_DLL`, else Steam's
default install folder. Use it to check FFI behaviour, garbage and compiled code in the game's own VM, which
differs from current LuaJIT builds (for example, it has no trace stitching).

## Lint

`lint.py` scans Lua sources for code that is unsafe in the shared state. `metrics.py` measures code
structure for rules R10-R15.

| Rule | Catches | Why |
| --- | --- | --- |
| R1 `global-cdef-function` | A function prototype in `ffi.cdef` without a private `__asm__` label. Also flagged: a label that repeats the name, a cdef argument that is not a literal, and a typedef or struct tag using a shared C or Windows type name (`uint8_t`, `DWORD`, `MEMORY_BASIC_INFORMATION`, `POINT`, `struct tagPOINT`, ...; list in `SHARED_TYPE_NAMES`). Typedefs with private names are fine. | `ffi.cdef` keeps the first prototype for a name in the whole process and silently ignores later ones; a type name keeps its first layout the same way (verified in both VMs). Use `void *x_GetModuleHandleA(const char *) __asm__("GetModuleHandleA");` and `typedef struct {...} x_region;`. |
| R2 `type-string` | `ffi.cast/typeof/new/metatype` (and `sizeof/alignof/istype/offsetof`) given a string, or a local string constant, that holds a function-pointer type `(*)` or an anonymous `struct {` / `union {` / `enum {` | Each evaluation creates new C types: 3 for a function-pointer string, 2 for an anonymous struct. The 65,536-entry table never frees them. Declare a named typedef once and reuse the ctype. |
| R3 `raw-store` | A store through `ffi.cast(...)[i] = v` or `.field = v`, or through a local cast from a constant address (`local WORDS = ffi.cast('uint32_t *', 0)`) | An access violation on a stale pointer kills the game, and `pcall` cannot catch it. Stores through other pointer variables are not detected. |
| R4 `gc-mutation` | `collectgarbage` with any option except `'count'`: no argument, a variable option, or `pcall(collectgarbage, 'stop')` | It changes the GC for the game and every mod, and running out of memory in compiled code kills the game. |
| R5 `jit-global` | `jit.flush`, any use of `jit.opt` (including `require('jit.opt')` and `<x>.opt.start`), `jit.attach`, and `jit.off()`/`jit.on()` with no argument. Local aliases of `jit` count too. | Each one affects every mod's compiled code. `jit.off(fn)` with an argument is fine. |
| R6 `os-clock` | `os.clock` | It aborts trace compilation (the game's LuaJIT has no trace stitching) and is coarse. Use the runtime's `time()`. |
| R7 `loader-version` | A numeric comparison with the loader's `version`: tables named `*loader*`, aliases of `CowboyBingusModLoader`, or `rawget(_G, '...Loader').version`. `type(loader.version)` is fine. | The Bingus Shared Loader's internal version differs from its release number (v18 reports 17). Check capabilities instead: `loader.api`, `loader.jit`, functions. |
| R8 `global-write` (sources only) | `GSET` instructions in the compiled bytecode, plus `rawset(_G, 'x', ...)`, `_G.x =` and `_G['x'] =`. `update`, `shutdown`, `render` and the repo's `allowed_globals` are exempt. | Any other global leaks into the shared state, such as an accidental `_`. |
| R9 `catch-previous` (sources only) | `pcall`/`xpcall` of `previous...`/`original...`, and `error((...), 0)` | Catching another layer's error and rethrowing it from the mod's frame makes vanilla errors look like mod errors. |
| R10 `cognitive-complexity` (sources only) | A function with cognitive complexity above 15 (see below) | Deeply nested branching is hard to follow and to test. The score grows with nesting, not length. Split the function into named helpers. |
| R11 `function-size` (sources only) | A function with more than 150 code lines of its own. Blank and comment-only lines do not count, nor do the bodies of nested functions, which are measured on their own. | A long function does several jobs. |
| R12 `parameters` (sources only) | A function with more than 7 parameters. `self` counts; `...` does not. | Every caller depends on the order of all of them. Pass a table. |
| R13 `luajit-limits` (sources only) | A function near one of LuaJIT's hard limits: more than 50 upvalues (limit 60), 200 stack slots (limit 250) or 180 active locals (limit 200, hidden `for` variables included). The main chunk counts too. | Past a limit the file stops compiling, so the mod does not load. Upvalues and stack slots come from the compiled bytecode. Active locals are counted from the source. |
| R14 `duplicated-code` (sources only) | A run of at least 100 tokens that also occurs elsewhere: in the same file, another file or another configured repo | A fix made in one copy misses the other. |
| R15 `module-size` (sources only) | A source file with more than 1000 code lines | A long file mixes concerns, and its main chunk heads for the 200-locals limit (R13). |

Suppression: put `-- lint-ok: R<n> <reason>` on the reported line. The reason is required. To
name several rules, write `R2,R3`. Inside a cdef string, use a C comment: `/* -- lint-ok: R1 reason */`.
R10-R12 are reported on the function's first line. R13 reports upvalues and stack slots there
too, but active locals on the line where the count peaks. R14 is reported on the first line of
the duplicated region, and R15 on the file's first line. An addon must keep that first line to
its exact `-- HD2-Addon:` declaration, so a large addon is accepted through the baseline instead.

The runtime files themselves pass every rule.

### Structure rules (R10-R15)

`metrics.py` measures every function on its own, closures included. Upvalue and stack-slot
counts come from the same compile pass as R8 (one `F` line per prototype).

Cognitive complexity follows SonarSource's 2017 definition, adapted to Lua:
- `if`, `while`, `for` and `repeat` each add 1, plus 1 for every enclosing `if` or loop;
- `elseif`, `else` and `goto` each add 1; `break` adds nothing;
- each run of the same boolean operator adds 1, so `a and b and c` adds 1 and
  `a and b or c` adds 2. A bracket or call argument starts a run of its own and leaves the
  outer run going: `a or f(b and c) or d` adds 2;
- a function that calls itself by its local name adds 1, once.

Unlike SonarSource, a closure is not charged to the function around it. It is measured on its
own, from nesting 0.

The limits are the defaults in `metrics.LIMITS`. To change them, add a `limits` object to the
config: `{"cognitive": 15, "function_lines": 150, "parameters": 7, "upvalues": 50,
"stack_slots": 200, "active_locals": 180, "module_lines": 1000, "clone_tokens": 100}`. Any key
may be left out; an unknown key stops the lint with exit code 2.

For R10-R15 the baseline stores the measured value: complexity, lines, parameters, the R13
count (locals, upvalues or stack slots) or duplicated tokens. A known function that gets worse
fails `check` (`baseline 16, now 17`), and one that improves is reported as "fixed - run update". A
file above 1000 lines may not grow without review.

R14 (duplicated code) works like PMD's CPD. It compares windows of 100 tokens across every
configured repo and every `--repo` override, whatever `--only` selects, and reports regions in
the selected repos. A window that matches only overlapping windows of the same file (a long
periodic table) is not a duplicate. Files kept byte-identical on purpose are left out:
`bingus_runtime.lua`, `bingus_memory.lua`, `bingus_write.lua`, `hostile_vm.lua`, `bingus_text.lua`
and `frame_budget.lua`. A `vendored` list in the config replaces these names.

How R8 works: `luajit -bl` prints no line numbers. `lint.py` therefore compiles every source
file (it never runs them) in one LuaJIT process, with `LUA_PATH` set to the folder of the LuaJIT
executable, which must hold LuaJIT's `jit/` modules (a LuaJIT `src` folder does). It lists each
`GSET` with the same `jit.bc` module that `-bl` uses, and takes its line from `jit.util.funcinfo`.
If a file does not compile, the lint stops with exit code 2.

### Running

```
python lint.py                           # repo x rule table
python lint.py scan --list               # every violation, with its detail
python lint.py scan --json               # machine-readable output
python lint.py check                     # exit 1 when any count rose above the baseline
python lint.py update                    # rewrite the baseline after fixes; refuses increases
python lint.py update --allow-increase   # accept increases: the first baseline, or reviewed changes
```

Options:
- `--tests` also lints `tests/` (rules R1-R7).
- `--repo NAME=PATH` lints another checkout against the baseline, for example a working branch:
  `python lint.py check --repo ShallowWaterDiving=../ShallowWaterDiving`. Repeat it for each repo of
  a release. Before a release, `check` must show no NEW line for those repos, or each one must be
  reviewed and accepted. After publishing, point the config at the new release checkouts and run
  `update`; accepted increases, such as a file that grew, need `--allow-increase`.
- `--only NAME` limits the scan, the check and the update to these repos.
- `--workspace PATH` sets the folder that relative paths in the config start from. The default is
  the `BINGUS_WORKSPACE` environment variable, else the folder that holds this repository.
- `--luajit PATH` sets the LuaJIT executable. The default is `BINGUS_LUAJIT`, else the config's
  `luajit`.
- `--config` and `--baseline` choose other files.

The baseline identity is (repo, kind, file, rule, line text with whitespace collapsed). Editing a
violating line gives it a new identity: `check` reports it as NEW and the old line as "fixed - run
update". Fix it or mark it `lint-ok`. Otherwise, after review, accept it with
`update --allow-increase`. `update` keeps entries outside the current scope: other repos when
`--only` is set, and test entries when `--tests` is not.

Exit codes: 0 means OK; 1 means new violations (`check`) or a refused update; 2 means a
configuration or compile error.

### Your own repo list

`lint-repos.json` and `lint-baseline.json` cover the CowboyBingus mods. To lint other mods, write
a config of the same shape and keep your own baseline:

```json
{
  "luajit": "tools/luajit/src/luajit.exe",
  "default_sources": ["src/**/*.lua"],
  "repos": [
    {"name": "MyMod", "path": "MyMod", "sources": ["src/**/*.lua"], "allowed_globals": ["MyMod"]}
  ]
}
```

```
python lint.py update --allow-increase --config my-repos.json --baseline my-baseline.json
python lint.py check --config my-repos.json --baseline my-baseline.json
```

`path` and `luajit` are relative to the workspace (see `--workspace`) or absolute. `sources` and
`tests` are globs relative to `path`; `default_sources` and `default_tests` apply to repos without
them. `allowed_globals` are the mod's own namespace globals; `update`, `shutdown` and `render` are
always allowed. `limits` and `vendored` are optional.

## Tests

```
python -m unittest discover -s tests -v
```

The Lua tests run twice: in a LuaJIT 2.1 executable (`BINGUS_LUAJIT`, else the `luajit` of
`lint-repos.json`) and in the game's `lua51.dll` through `game_lua.py` (`HD2_LUA51_DLL`, else
Steam's default install folder). A missing VM skips its tests.

- `test_runtime.py` runs five Lua tests in both VMs, plus checks on the sources: the core and the
  read side contain none of the names that read-only builds refuse, the core uses no FFI and names
  no Windows function, and every FFI name is private and versioned.
  - `test_core.lua`: the shared table and its repair, and the whole guard policy against hostile
    neighbours (`throw_below`, `double_call`, `drop_args`, `rehook`, `skip_odd_frames`). It also
    checks that the core reads no global besides a few Lua builtins.
  - `test_memory.lua`: reads, pointers, addresses and page checks against this process's real
    memory, including read-only, guard, executable, image and unmapped pages; `time()` (monotonic,
    in seconds); module hashes once per session for every copy. It pins 0 bytes of garbage per call
    for `read_into`, `writable_data`, `address`, `distance` and `time`, interpreted and compiled,
    the Windows calls per call, and no C types per call or per copy.
  - `test_write.lua`: writes and refusals on read-only, guard, executable, image and unmapped
    pages; batches; one page query per region; 0 bytes of garbage per write.
  - `test_together.lua`: two copies of each file, a copy of a second version beside them, guards of
    every copy on one chain, and a typical guarded loop that allocates nothing across JIT flushes
    and a hostile GC pause.
  - `test_hostile_runtime.lua`: another mod declared every Windows function the runtime uses first,
    once with Windows SDK prototypes and once with `H.clash`; the runtime and the neighbour both
    keep working.
- `test_hostile_vm.py` runs `tests/test_hostile_vm.lua` in both VMs.
- `test_lint.py` covers every rule, the `lint-ok` comment and the baseline ratchet. In
  `tests/fixtures/sample_mod`, each expected violation is marked `expect: R<n>`, and a scan must
  report exactly the marked lines. The `r10_` to `r15_` fixtures put a function exactly at each
  limit (silent) beside one just over it (reported).
- `test_metrics.py` checks cognitive complexity against SonarSource's examples (`sum_of_primes`
  scores 7), boolean runs, nesting, recursion and closures, LuaJIT's local count with hidden `for`
  variables, and duplicated-code regions.

Each runtime test was checked against deliberate bugs: 40 mutations of the three files, each one
caught in both VMs.

**AI disclosure:** Claude Opus 5.5 assisted with research, implementation, tests and documentation.
